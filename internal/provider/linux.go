package provider

import (
	"bytes"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/spektral-tech/zts/internal/alloc"
	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/wgctrl"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// Linux is the provider for one substrate namespace.
type Linux struct {
	Name string
	Log  func(string, ...any)
}

func (l *Linux) logf(f string, a ...any) {
	if l.Log != nil {
		l.Log(f, a...)
	}
}

func (l *Linux) ns() (netns.NsHandle, error) { return OpenNs(l.Name) }

func (l *Linux) handle() (netns.NsHandle, *netlink.Handle, error) {
	ns, err := l.ns()
	if err != nil {
		return ns, nil, err
	}
	h, err := netlink.NewHandleAt(ns)
	if err != nil {
		ns.Close()
		return ns, nil, err
	}
	return ns, h, nil
}

// ---------- observation ----------

func (l *Linux) ZifExists(zif string) bool {
	if !NsExists(l.Name) {
		return false
	}
	ns, h, err := l.handle()
	if err != nil {
		return false
	}
	defer ns.Close()
	defer h.Close()
	_, err = h.LinkByName(zif)
	return err == nil
}

func (l *Linux) HostlinkExists() bool {
	if _, err := netlink.LinkByName(HostlinkHostIf); err != nil {
		return false
	}
	return l.ZifExists(HostlinkNsIf)
}

func (l *Linux) ContainerEth0Matches(w *Workload) bool {
	cns, err := netns.GetFromPid(w.PID)
	if err != nil {
		return false
	}
	defer cns.Close()
	h, err := netlink.NewHandleAt(cns)
	if err != nil {
		return false
	}
	defer h.Close()
	eth0, err := h.LinkByName("eth0")
	if err != nil {
		return false
	}
	addrs, _ := h.AddrList(eth0, netlink.FAMILY_V4)
	ok := false
	for _, a := range addrs {
		if a.IP.Equal(w.IP) {
			if p, _ := a.Mask.Size(); p == 30 {
				ok = true
			}
		}
	}
	if !ok {
		return false
	}
	routes, _ := h.RouteList(eth0, netlink.FAMILY_V4)
	for _, r := range routes {
		isDefault := r.Dst == nil
		if r.Dst != nil {
			if ones, _ := r.Dst.Mask.Size(); ones == 0 {
				isDefault = true
			}
		}
		if isDefault && r.Gw != nil && r.Gw.Equal(w.GW) {
			return true
		}
	}
	return false
}

var hashRe = regexp.MustCompile(`comment "zts-state:([0-9]+)"`)

func (l *Linux) CurrentPolicyHash() string {
	if !NsExists(l.Name) {
		return "none"
	}
	out, err := l.nft("list", "table", "inet", "zts")
	if err != nil {
		return "none"
	}
	if m := hashRe.FindSubmatch(out); m != nil {
		return string(m[1])
	}
	return "none"
}

// nft runs the nft binary inside the substrate namespace.
func (l *Linux) nft(args ...string) ([]byte, error) {
	ns, err := l.ns()
	if err != nil {
		return nil, err
	}
	defer ns.Close()
	var out []byte
	err = InNs(ns, func() error {
		var e error
		out, e = exec.Command("nft", args...).CombinedOutput()
		return e
	})
	return out, err
}

func (l *Linux) nftApply(text string) error {
	ns, err := l.ns()
	if err != nil {
		return err
	}
	defer ns.Close()
	return InNs(ns, func() error {
		cmd := exec.Command("nft", "-f", "-")
		cmd.Stdin = strings.NewReader(text)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("nft: %v: %s", err, out)
		}
		return nil
	})
}

// ---------- materialization ----------

func (l *Linux) EnsureNamespace() error {
	if !NsExists(l.Name) {
		if err := NsAdd(l.Name); err != nil {
			return err
		}
		if _, err := OpenNs(l.Name); err != nil {
			_ = NsDel(l.Name)
			return fmt.Errorf("namespace creation produced an unusable namespace: %v", err)
		}
	}
	ns, h, err := l.handle()
	if err != nil {
		return err
	}
	defer ns.Close()
	defer h.Close()
	lo, err := h.LinkByName("lo")
	if err == nil {
		_ = h.LinkSetUp(lo)
	}
	return InNs(ns, func() error {
		_ = sysctl("net/ipv4/ip_forward", "1")
		_ = sysctl("net/ipv4/conf/all/rp_filter", "0")
		_ = sysctl("net/ipv4/conf/default/rp_filter", "0")
		_ = sysctl("net/ipv6/conf/all/disable_ipv6", "1")
		return nil
	})
}

func ipnet(ip string, bits int) *net.IPNet {
	return &net.IPNet{IP: net.ParseIP(ip).To4(), Mask: net.CIDRMask(bits, 32)}
}

func (l *Linux) EnsureHostLink(pool *net.IPNet) error {
	ns, h, err := l.handle()
	if err != nil {
		return err
	}
	defer ns.Close()
	defer h.Close()
	if !l.HostlinkExists() {
		if lk, err := netlink.LinkByName(HostlinkHostIf); err == nil {
			_ = netlink.LinkDel(lk)
		}
		if lk, err := h.LinkByName(HostlinkNsIf); err == nil {
			_ = h.LinkDel(lk)
		}
		veth := &netlink.Veth{LinkAttrs: netlink.LinkAttrs{Name: HostlinkHostIf}, PeerName: HostlinkNsIf}
		if err := netlink.LinkAdd(veth); err != nil {
			return fmt.Errorf("host link: %v", err)
		}
		peer, err := netlink.LinkByName(HostlinkNsIf)
		if err != nil {
			return err
		}
		if err := netlink.LinkSetNsFd(peer, int(ns)); err != nil {
			return err
		}
	}
	hostIf, err := netlink.LinkByName(HostlinkHostIf)
	if err != nil {
		return err
	}
	_ = netlink.AddrReplace(hostIf, &netlink.Addr{IPNet: ipnet(HostlinkHostIP, 30)})
	if err := netlink.LinkSetUp(hostIf); err != nil {
		return err
	}
	nsIf, err := h.LinkByName(HostlinkNsIf)
	if err != nil {
		return err
	}
	_ = h.AddrReplace(nsIf, &netlink.Addr{IPNet: ipnet(HostlinkNsIP, 30)})
	if err := h.LinkSetUp(nsIf); err != nil {
		return err
	}
	// Host: return path for the workload pool; forwarding on.
	if err := netlink.RouteReplace(&netlink.Route{Dst: pool, Gw: net.ParseIP(HostlinkNsIP).To4(), LinkIndex: hostIf.Attrs().Index}); err != nil {
		return fmt.Errorf("host route: %v", err)
	}
	_ = sysctl("net/ipv4/ip_forward", "1")
	_ = sysctl("net/ipv4/conf/"+HostlinkHostIf+"/rp_filter", "0")
	// Namespace main table: how the resolvers reach upstream.
	if err := h.RouteReplace(&netlink.Route{Gw: net.ParseIP(HostlinkHostIP).To4(), LinkIndex: nsIf.Attrs().Index}); err != nil {
		return fmt.Errorf("ns default route: %v", err)
	}
	// Host-side NAT and forwarding for the pool (and the resolver's own address).
	rules := fmt.Sprintf(`table inet zts_host {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr { %s, %s } oifname != "%s" masquerade
  }
  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    iifname "%s" accept
    oifname "%s" ct state established,related accept
  }
}
`, pool, HostlinkNsIP, HostlinkHostIf, HostlinkHostIf, HostlinkHostIf)
	cmd := exec.Command("nft", "-f", "-")
	cmd.Stdin = strings.NewReader(rules)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("host nft: %v: %s", err, out)
	}
	// Docker keeps a DROP policy on FORWARD and documents DOCKER-USER as the
	// chain for user rules.
	if ipt := dockerUserIptables(); ipt != "" {
		if exec.Command(ipt, "-C", "DOCKER-USER", "-i", HostlinkHostIf, "-j", "ACCEPT").Run() != nil {
			_ = exec.Command(ipt, "-I", "DOCKER-USER", "1", "-i", HostlinkHostIf, "-j", "ACCEPT").Run()
		}
		if exec.Command(ipt, "-C", "DOCKER-USER", "-o", HostlinkHostIf, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT").Run() != nil {
			_ = exec.Command(ipt, "-I", "DOCKER-USER", "1", "-o", HostlinkHostIf, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT").Run()
		}
	}
	return nil
}

func dockerUserIptables() string {
	for _, b := range []string{"iptables-nft", "iptables-legacy", "iptables"} {
		if _, err := exec.LookPath(b); err != nil {
			continue
		}
		if exec.Command(b, "-S", "DOCKER-USER").Run() == nil {
			return b
		}
	}
	return ""
}

func (l *Linux) RemoveHostLink() {
	if ipt := dockerUserIptables(); ipt != "" {
		_ = exec.Command(ipt, "-D", "DOCKER-USER", "-i", HostlinkHostIf, "-j", "ACCEPT").Run()
		_ = exec.Command(ipt, "-D", "DOCKER-USER", "-o", HostlinkHostIf, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT").Run()
	}
	_ = exec.Command("nft", "delete", "table", "inet", "zts_host").Run()
	if lk, err := netlink.LinkByName(HostlinkHostIf); err == nil {
		_ = netlink.LinkDel(lk)
	}
}

func (l *Linux) EnsureWireguard(inv *Inventory, name string) error {
	t := inv.M.Transports[name]
	ifn := alloc.TransportIfname(name)
	keyb, err := os.ReadFile(t.PrivateKeyFile)
	if err != nil {
		return fmt.Errorf("transport '%s': cannot read private key file '%s'", name, t.PrivateKeyFile)
	}
	priv, err := wgtypes.ParseKey(strings.TrimSpace(string(keyb)))
	if err != nil {
		return fmt.Errorf("transport '%s': bad private key: %v", name, err)
	}
	pub, err := wgtypes.ParseKey(t.Peer.PublicKey)
	if err != nil {
		return fmt.Errorf("transport '%s': bad peer public key: %v", name, err)
	}
	ns, h, err := l.handle()
	if err != nil {
		return err
	}
	defer ns.Close()
	defer h.Close()
	if _, err := h.LinkByName(ifn); err != nil {
		// Create in the host namespace, then move it: WireGuard keeps its UDP
		// socket where the interface was created, plaintext lives in zts only.
		if _, err := netlink.LinkByName(ifn); err == nil {
			return fmt.Errorf("host interface '%s' already exists", ifn)
		}
		if err := netlink.LinkAdd(&netlink.Wireguard{LinkAttrs: netlink.LinkAttrs{Name: ifn}}); err != nil {
			return fmt.Errorf("wireguard link: %v", err)
		}
		lk, _ := netlink.LinkByName(ifn)
		if err := netlink.LinkSetNsFd(lk, int(ns)); err != nil {
			return err
		}
	}
	lk, err := h.LinkByName(ifn)
	if err != nil {
		return err
	}
	addrs, _ := h.AddrList(lk, netlink.FAMILY_V4)
	for _, a := range addrs {
		_ = h.AddrDel(lk, &a)
	}
	addr, err := netlink.ParseAddr(t.Address)
	if err != nil {
		return err
	}
	if err := h.AddrAdd(lk, addr); err != nil {
		return err
	}
	ep, err := net.ResolveUDPAddr("udp", t.Peer.Endpoint)
	if err != nil {
		return fmt.Errorf("transport '%s': endpoint: %v", name, err)
	}
	var allowed []net.IPNet
	for _, a := range t.Peer.AllowedIPs {
		_, n, _ := net.ParseCIDR(a)
		allowed = append(allowed, *n)
	}
	ka := time.Duration(t.Peer.PersistentKeepalive) * time.Second
	cfg := wgtypes.Config{PrivateKey: &priv, ReplacePeers: true, Peers: []wgtypes.PeerConfig{{
		PublicKey: pub, Endpoint: ep, AllowedIPs: allowed, PersistentKeepaliveInterval: &ka, ReplaceAllowedIPs: true,
	}}}
	if err := InNs(ns, func() error {
		c, err := wgctrl.New()
		if err != nil {
			return err
		}
		defer c.Close()
		return c.ConfigureDevice(ifn, cfg)
	}); err != nil {
		return fmt.Errorf("transport '%s': %v", name, err)
	}
	return h.LinkSetUp(lk)
}

func (l *Linux) CleanupStaleEndpoints(inv *Inventory) error {
	ns, h, err := l.handle()
	if err != nil {
		return err
	}
	defer ns.Close()
	defer h.Close()
	links, err := h.LinkList()
	if err != nil {
		return err
	}
	for _, lk := range links {
		name := lk.Attrs().Name
		if !strings.HasPrefix(name, "zt") {
			continue
		}
		expected := false
		for _, w := range inv.Workloads {
			if w.Zif == name {
				expected = true
				break
			}
		}
		if !expected {
			l.logf("remove stale endpoint %s", name)
			_ = h.LinkDel(lk)
		}
	}
	return nil
}

func (l *Linux) writeResolv(w *Workload) {
	if w.ResolvPath == "" {
		l.logf("warning: %s: no ResolvConfPath from Docker; names will not resolve", w.Identity)
		return
	}
	p := filepath.Join(HostRoot, w.ResolvPath)
	if _, err := os.Stat(p); err != nil {
		l.logf("warning: %s: resolv.conf not reachable at %s; names will not resolve", w.Identity, p)
		return
	}
	_ = os.WriteFile(p, []byte(fmt.Sprintf("nameserver %s\noptions ndots:0\n", w.GW)), 0o644)
}

func (l *Linux) EnsureEndpoint(w *Workload) error {
	ns, h, err := l.handle()
	if err != nil {
		return err
	}
	defer ns.Close()
	defer h.Close()
	if zl, err := h.LinkByName(w.Zif); err == nil && l.ContainerEth0Matches(w) {
		_ = h.LinkSetUp(zl)
		l.writeResolv(w)
		return nil
	} else if err == nil {
		_ = h.LinkDel(zl)
	}
	cns, err := netns.GetFromPid(w.PID)
	if err != nil {
		return fmt.Errorf("%s: container netns: %v", w.Identity, err)
	}
	defer cns.Close()
	ch, err := netlink.NewHandleAt(cns)
	if err != nil {
		return err
	}
	defer ch.Close()
	if _, err := ch.LinkByName("eth0"); err == nil {
		return fmt.Errorf("%s: eth0 exists but is not attached to the expected ZTS endpoint; refusing to replace it", w.Identity)
	}
	tmp := "c" + strings.TrimPrefix(w.Zif, "zt")
	if err := netlink.LinkAdd(&netlink.Veth{LinkAttrs: netlink.LinkAttrs{Name: w.Zif}, PeerName: tmp}); err != nil {
		return fmt.Errorf("%s: veth: %v", w.Identity, err)
	}
	zl, _ := netlink.LinkByName(w.Zif)
	if err := netlink.LinkSetNsFd(zl, int(ns)); err != nil {
		return err
	}
	tl, _ := netlink.LinkByName(tmp)
	if err := netlink.LinkSetNsPid(tl, w.PID); err != nil {
		return err
	}
	zl, _ = h.LinkByName(w.Zif)
	if err := h.AddrAdd(zl, &netlink.Addr{IPNet: &net.IPNet{IP: w.GW, Mask: net.CIDRMask(30, 32)}}); err != nil {
		return err
	}
	if err := h.LinkSetUp(zl); err != nil {
		return err
	}
	if lo, err := ch.LinkByName("lo"); err == nil {
		_ = ch.LinkSetUp(lo)
	}
	tl, err = ch.LinkByName(tmp)
	if err != nil {
		return err
	}
	if err := ch.LinkSetName(tl, "eth0"); err != nil {
		return err
	}
	eth0, _ := ch.LinkByName("eth0")
	if err := ch.AddrAdd(eth0, &netlink.Addr{IPNet: &net.IPNet{IP: w.IP, Mask: net.CIDRMask(30, 32)}}); err != nil {
		return err
	}
	if err := ch.LinkSetUp(eth0); err != nil {
		return err
	}
	if err := ch.RouteReplace(&netlink.Route{Gw: w.GW, LinkIndex: eth0.Attrs().Index}); err != nil {
		return err
	}
	_ = InNs(cns, func() error { return sysctl("net/ipv6/conf/all/disable_ipv6", "1") })
	l.writeResolv(w)
	return nil
}

func (l *Linux) ReconcileRouting(inv *Inventory) error {
	ns, h, err := l.handle()
	if err != nil {
		return err
	}
	defer ns.Close()
	defer h.Close()
	// Remove only rules at our priority, flushing their tables first.
	rules, err := h.RuleList(netlink.FAMILY_V4)
	if err != nil {
		return err
	}
	for _, r := range rules {
		if r.Priority != alloc.RulePref {
			continue
		}
		routes, _ := h.RouteListFiltered(netlink.FAMILY_V4, &netlink.Route{Table: r.Table}, netlink.RT_FILTER_TABLE)
		for _, rt := range routes {
			_ = h.RouteDel(&rt)
		}
		rr := r
		_ = h.RuleDel(&rr)
	}
	defaultDst := &net.IPNet{IP: net.IPv4zero.To4(), Mask: net.CIDRMask(0, 32)}
	for _, rs := range inv.Routes() {
		// netlink wants an explicit destination; 0.0.0.0/0 is "default".
		rt := &netlink.Route{Table: rs.Table, Priority: rs.Metric, Dst: defaultDst}
		if rs.Dst != nil {
			if ones, _ := rs.Dst.Mask.Size(); ones > 0 {
				rt.Dst = rs.Dst
			}
		}
		if rs.Unreachable {
			rt.Type = unix.RTN_UNREACHABLE
		} else {
			lk, err := h.LinkByName(rs.Dev)
			if err != nil {
				return fmt.Errorf("route %s: %v", rs, err)
			}
			rt.LinkIndex = lk.Attrs().Index
			if rs.Via != nil {
				rt.Gw = rs.Via
			} else if rs.Dst != nil {
				rt.Scope = netlink.SCOPE_LINK
			}
		}
		if err := h.RouteReplace(rt); err != nil {
			return fmt.Errorf("route %s: %v", rs, err)
		}
	}
	for _, w := range inv.Workloads {
		r := netlink.NewRule()
		r.Priority = alloc.RulePref
		r.Family = netlink.FAMILY_V4
		r.Src = &net.IPNet{IP: w.IP, Mask: net.CIDRMask(32, 32)}
		r.Table = w.Table
		if err := h.RuleAdd(r); err != nil {
			return fmt.Errorf("rule for %s: %v", w.Identity, err)
		}
	}
	return nil
}

func (l *Linux) ReconcileNftables(inv *Inventory) error {
	var b bytes.Buffer
	if _, err := l.nft("list", "table", "inet", "zts"); err == nil {
		b.WriteString("delete table inet zts\n")
	}
	fmt.Fprintf(&b, "add table inet zts { comment \"zts-state:%s\"; }\n", inv.PolicyHash())
	b.WriteString(inv.Ruleset())
	return l.nftApply(b.String())
}

func (l *Linux) ReconcileResolvers(inv *Inventory) error {
	return ApplyResolvers(l.Name, inv.Resolvers(), inv.M.Substrate.Resolvers)
}

func (l *Linux) Verify(inv *Inventory) error {
	if !NsExists(l.Name) {
		return fmt.Errorf("verification: namespace '%s' missing", l.Name)
	}
	if _, err := l.nft("list", "table", "inet", "zts"); err != nil {
		return fmt.Errorf("verification: nft table missing")
	}
	ns, h, err := l.handle()
	if err != nil {
		return err
	}
	defer ns.Close()
	defer h.Close()
	rules, _ := h.RuleList(netlink.FAMILY_V4)
	for _, w := range inv.Workloads {
		if _, err := h.LinkByName(w.Zif); err != nil {
			return fmt.Errorf("verification: endpoint '%s' missing", w.Zif)
		}
		if !l.ContainerEth0Matches(w) {
			return fmt.Errorf("verification: '%s' container endpoint mismatch", w.Identity)
		}
		found := false
		for _, r := range rules {
			if r.Priority == alloc.RulePref && r.Table == w.Table && r.Src != nil && r.Src.IP.Equal(w.IP) {
				found = true
			}
		}
		if !found {
			return fmt.Errorf("verification: '%s' policy rule missing", w.Identity)
		}
	}
	if inv.PolicyHash() != l.CurrentPolicyHash() {
		return fmt.Errorf("verification: policy hash mismatch")
	}
	return nil
}

// Apply converges kernel state to the inventory.
func (l *Linux) Apply(inv *Inventory) error {
	if err := l.EnsureNamespace(); err != nil {
		return err
	}
	if inv.HostName == "" {
		l.RemoveHostLink()
	}
	for _, t := range inv.M.TransportNames() {
		l.logf("reconcile transport %s", t)
		var err error
		if inv.M.Transports[t].Kind() == "host" {
			err = l.EnsureHostLink(inv.Pool)
		} else {
			err = l.EnsureWireguard(inv, t)
		}
		if err != nil {
			return err
		}
	}
	if err := l.CleanupStaleEndpoints(inv); err != nil {
		return err
	}
	for _, w := range inv.Workloads {
		l.logf("reconcile workload %s", w.Identity)
		if err := l.EnsureEndpoint(w); err != nil {
			return err
		}
	}
	l.logf("reconcile routing")
	if err := l.ReconcileRouting(inv); err != nil {
		return err
	}
	l.logf("reconcile nftables")
	if err := l.ReconcileNftables(inv); err != nil {
		return err
	}
	l.logf("reconcile resolvers")
	if err := l.ReconcileResolvers(inv); err != nil {
		return err
	}
	if err := l.Verify(inv); err != nil {
		return err
	}
	l.logf("converged (%d workload(s))", len(inv.Workloads))
	return nil
}

func (l *Linux) Destroy() error {
	StopResolvers()
	l.RemoveHostLink()
	if NsExists(l.Name) {
		l.logf("delete namespace %s (all ZTS veth/WireGuard/kernel state disappears with it)", l.Name)
		return NsDel(l.Name)
	}
	l.logf("namespace %s already absent", l.Name)
	return nil
}

// StaleEndpoints lists zt* interfaces in the namespace that no workload owns.
func (l *Linux) StaleEndpoints(inv *Inventory) []string {
	if !NsExists(l.Name) {
		return nil
	}
	ns, h, err := l.handle()
	if err != nil {
		return nil
	}
	defer ns.Close()
	defer h.Close()
	links, _ := h.LinkList()
	var out []string
	for _, lk := range links {
		name := lk.Attrs().Name
		if !strings.HasPrefix(name, "zt") {
			continue
		}
		expected := false
		for _, w := range inv.Workloads {
			if w.Zif == name {
				expected = true
			}
		}
		if !expected {
			out = append(out, name)
		}
	}
	return out
}
