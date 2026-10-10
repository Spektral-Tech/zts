package provider

import (
	"fmt"
	"net"
	"sort"
	"strings"

	"github.com/spektral-tech/zts/internal/alloc"
	"github.com/spektral-tech/zts/internal/manifest"
)

const (
	HostlinkHostIf = "zts-host"
	HostlinkNsIf   = "host0"
	HostlinkHostIP = "169.254.100.1"
	HostlinkNsIP   = "169.254.100.2"
)

// routeSpec is one route in a profile table, in iproute2 vocabulary.
type routeSpec struct {
	Dst         *net.IPNet // nil = default
	Via         net.IP
	Dev         string
	Metric      int
	Table       int
	Unreachable bool
}

func (r routeSpec) String() string {
	dst := "default"
	if r.Dst != nil {
		dst = r.Dst.String()
	}
	var b strings.Builder
	if r.Unreachable {
		b.WriteString("unreachable ")
	}
	b.WriteString(dst)
	if r.Via != nil {
		fmt.Fprintf(&b, " via %s", r.Via)
	}
	if r.Dev != "" {
		fmt.Fprintf(&b, " dev %s", r.Dev)
	}
	if r.Metric > 0 {
		fmt.Fprintf(&b, " metric %d", r.Metric)
	}
	fmt.Fprintf(&b, " table %d", r.Table)
	return b.String()
}

func (inv *Inventory) transportTarget(t string) (via net.IP, dev string) {
	if inv.M.Transports[t].Kind() == "host" {
		return net.ParseIP(HostlinkHostIP).To4(), HostlinkNsIf
	}
	return nil, alloc.TransportIfname(t)
}

func (inv *Inventory) transportOif(t string) string {
	_, dev := inv.transportTarget(t)
	return dev
}

func mustCIDR(s string) *net.IPNet {
	_, n, err := net.ParseCIDR(s)
	if err != nil {
		panic(err)
	}
	return n
}

// Routes renders every route of every profile table, in a fixed order.
func (inv *Inventory) Routes() []routeSpec {
	var out []routeSpec
	for _, p := range inv.Profiles {
		table := inv.Table[p]
		// Local workload routes are present in every profile table so established
		// replies can return. nftables, not route existence, authorizes new flows.
		for _, w := range inv.Workloads {
			out = append(out, routeSpec{Dst: &net.IPNet{IP: w.IP, Mask: net.CIDRMask(32, 32)}, Dev: w.Zif, Table: table})
		}
		for _, a := range inv.M.Profiles[p].Allow {
			r := inv.M.Resources[a.To]
			if r.Workload != "" {
				continue
			}
			via, dev := inv.transportTarget(a.Via)
			for _, c := range r.CIDRs {
				out = append(out, routeSpec{Dst: mustCIDR(c), Via: via, Dev: dev, Metric: 100, Table: table})
			}
		}
		if nv, ok := inv.NameVia[p]; ok {
			// Name-based reachability can land on any address; the route is broad,
			// the nftables set is the authorization.
			via, dev := inv.transportTarget(nv)
			out = append(out, routeSpec{Via: via, Dev: dev, Metric: 200, Table: table})
		}
		// Fail closed: a destination without a more-specific desired route stops
		// here instead of falling through to the namespace main table.
		out = append(out, routeSpec{Unreachable: true, Metric: 32760, Table: table})
	}
	return out
}

func portExpr(a manifest.Allow) string {
	if a.Proto() == "any" || len(a.Ports) == 0 {
		return ""
	}
	if len(a.Ports) == 1 {
		return fmt.Sprintf(" %s dport %d", a.Proto(), a.Ports[0])
	}
	ps := make([]string, len(a.Ports))
	for i, p := range a.Ports {
		ps[i] = fmt.Sprint(p)
	}
	return fmt.Sprintf(" %s dport { %s }", a.Proto(), strings.Join(ps, ", "))
}

func protoExpr(a manifest.Allow) string {
	if a.Proto() == "any" {
		return ""
	}
	return " meta l4proto " + a.Proto()
}

// Ruleset renders the nftables policy for the substrate namespace.
func (inv *Inventory) Ruleset() string {
	var b strings.Builder
	b.WriteString(`add chain inet zts antispoof
add chain inet zts input { type filter hook input priority filter; policy drop; }
add chain inet zts forward { type filter hook forward priority filter; policy drop; }
add rule inet zts input iifname "lo" accept
add rule inet zts input ct state established,related accept
add rule inet zts input jump antispoof
add rule inet zts forward ct state invalid drop
add rule inet zts forward ct state established,related accept
add rule inet zts forward jump antispoof
`)
	// Bind source identity to the kernel-created ingress interface; DNS only to
	// the workload's own gateway.
	for _, w := range inv.Workloads {
		fmt.Fprintf(&b, "add rule inet zts antispoof iifname \"%s\" ip saddr != %s drop\n", w.Zif, w.IP)
		fmt.Fprintf(&b, "add rule inet zts input iifname \"%s\" ip daddr %s meta l4proto { tcp, udp } th dport 53 accept\n", w.Zif, w.GW)
	}
	// Sets for name-based resources (populated by the resolver).
	done := map[string]bool{}
	for _, p := range inv.Profiles {
		for _, a := range inv.M.Profiles[p].Allow {
			r := inv.M.Resources[a.To]
			if !r.HasNames() || done[a.To] {
				continue
			}
			done[a.To] = true
			fmt.Fprintf(&b, "add set inet zts %s { type ipv4_addr; flags timeout; timeout 1h; }\n", alloc.ResourceSetname(a.To))
		}
	}
	// Order matters:
	//  1. CIDR relations that explicitly name private space (trusted on purpose)
	//  2. host-transport guard
	//  3. every other CIDR relation and name-based relations
	//  4. workload-to-workload relations
	for _, phase := range []string{"private", "public"} {
		if phase == "public" && inv.HostName != "" && !inv.HostAllowPrivate {
			fmt.Fprintf(&b, "add rule inet zts forward oifname \"%s\" ip daddr { %s } drop\n", HostlinkNsIf, strings.Join(alloc.PrivateRanges, ", "))
		}
		for _, w := range inv.Workloads {
			for _, a := range inv.M.Profiles[w.Profile].Allow {
				r := inv.M.Resources[a.To]
				if r.Workload != "" {
					continue
				}
				oif := inv.transportOif(a.Via)
				for _, c := range r.CIDRs {
					priv := alloc.CIDRIsPrivate(mustCIDR(c))
					if (phase == "private") != priv {
						continue
					}
					fmt.Fprintf(&b, "add rule inet zts forward iifname \"%s\" oifname \"%s\" ip daddr %s%s%s accept\n", w.Zif, oif, c, protoExpr(a), portExpr(a))
				}
			}
		}
	}
	for _, w := range inv.Workloads {
		for _, a := range inv.M.Profiles[w.Profile].Allow {
			r := inv.M.Resources[a.To]
			if r.Workload != "" {
				t := inv.byIdentity(r.Workload)
				fmt.Fprintf(&b, "add rule inet zts forward iifname \"%s\" oifname \"%s\" ip daddr %s%s%s accept\n", w.Zif, t.Zif, t.IP, protoExpr(a), portExpr(a))
				continue
			}
			if !r.HasNames() {
				continue
			}
			oif := inv.transportOif(a.Via)
			if r.AnyName() {
				// "*" means any name: wide open on this transport for the declared
				// protocol/ports (the host guard still applies).
				fmt.Fprintf(&b, "add rule inet zts forward iifname \"%s\" oifname \"%s\"%s%s accept\n", w.Zif, oif, protoExpr(a), portExpr(a))
			} else {
				fmt.Fprintf(&b, "add rule inet zts forward iifname \"%s\" oifname \"%s\" ip daddr @%s%s%s accept\n", w.Zif, oif, alloc.ResourceSetname(a.To), protoExpr(a), portExpr(a))
			}
		}
	}
	return b.String()
}

// ResolverConfig is what the embedded resolver serves for one profile.
type ResolverConfig struct {
	Profile string
	Listen  []net.IP          // gateway addresses of the profile's workloads
	Any     bool              // "*" declared: forward every name
	Sets    map[string]string // domain (without "*.") -> nft set name
}

func (inv *Inventory) Resolvers() []ResolverConfig {
	var out []ResolverConfig
	for _, p := range inv.Profiles {
		if _, ok := inv.NameVia[p]; !ok {
			continue
		}
		rc := ResolverConfig{Profile: p, Sets: map[string]string{}}
		for _, w := range inv.workloadsOf(p) {
			rc.Listen = append(rc.Listen, w.GW)
		}
		for _, a := range inv.M.Profiles[p].Allow {
			r := inv.M.Resources[a.To]
			for _, n := range r.Names {
				if n == "*" {
					rc.Any = true
					continue
				}
				rc.Sets[strings.TrimPrefix(n, "*.")] = alloc.ResourceSetname(a.To)
			}
		}
		out = append(out, rc)
	}
	return out
}

// PolicyText is the whole desired policy; its hash is stored in the nft table
// comment so plan/status can tell converged from drift without a state file.
func (inv *Inventory) PolicyText() string {
	var b strings.Builder
	b.WriteString(inv.Ruleset())
	b.WriteString("--- routes ---\n")
	for _, r := range inv.Routes() {
		b.WriteString(r.String())
		b.WriteByte('\n')
	}
	b.WriteString("--- dns ---\n")
	for _, rc := range inv.Resolvers() {
		fmt.Fprintf(&b, "profile=%s any=%v listen=%v\n", rc.Profile, rc.Any, rc.Listen)
		keys := make([]string, 0, len(rc.Sets))
		for k := range rc.Sets {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			fmt.Fprintf(&b, "%s -> %s\n", k, rc.Sets[k])
		}
	}
	b.WriteString("resolvers=" + strings.Join(inv.M.Substrate.Resolvers, ",") + "\n")
	return b.String()
}

func (inv *Inventory) PolicyHash() string {
	return fmt.Sprint(alloc.Cksum([]byte(inv.PolicyText())))
}
