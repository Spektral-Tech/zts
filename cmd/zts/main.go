// zts materializes, per container, only the network a manifest declares.
package main

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/spektral-tech/zts/internal/alloc"
	"github.com/spektral-tech/zts/internal/docker"
	"github.com/spektral-tech/zts/internal/manifest"
	"github.com/spektral-tech/zts/internal/provider"
)

func info(f string, a ...any) { fmt.Fprintf(os.Stderr, "[zts] "+f+"\n", a...) }
func die(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "[zts] error: "+f+"\n", a...)
	os.Exit(1)
}

func usage() {
	fmt.Fprint(os.Stderr, `Usage:
  zts init     [manifest.yaml]   write a manifest from a preset
  zts check    [manifest.yaml]   validate a manifest (no root needed)
  zts plan     [manifest.yaml]
  zts apply    [manifest.yaml]
  zts status   [manifest.yaml]
  zts up       [manifest.yaml]   apply and keep reconciling on container events
  zts destroy  [manifest.yaml]
  zts selftest
`)
}

func manifestPath(args []string) string {
	if len(args) > 1 {
		return args[1]
	}
	if st, err := os.Stat("/etc/zts"); err == nil && st.IsDir() {
		return "/etc/zts/zts.yaml"
	}
	return "zts.yaml"
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(0)
	}
	cmd := os.Args[1]
	path := manifestPath(os.Args[1:])
	switch cmd {
	case "-h", "--help", "help":
		usage()
		return
	case "selftest":
		selftest()
		return
	case "resolver":
		// Internal: the detached per-profile resolver process.
		if len(os.Args) < 3 {
			die("resolver: spec file required")
		}
		if err := provider.ServeResolver(os.Args[2]); err != nil {
			die("resolver: %v", err)
		}
		return
	case "check":
		if _, err := manifest.Check(path); err != nil {
			die("%v", err)
		}
		fmt.Printf("manifest ok: %s\n", path)
		return
	case "init":
		runInit(path, true)
		return
	case "plan", "apply", "status", "up", "destroy":
	default:
		usage()
		die("unknown command '%s'", cmd)
	}

	if os.Geteuid() != 0 {
		die("must run as root")
	}
	dc := docker.New()
	if err := dc.Available(); err != nil {
		die("%v", err)
	}
	if cmd == "up" {
		if _, err := os.Stat(path); err != nil && os.Getenv("ZTS_PRESET") != "" {
			runInit(path, false)
		}
	}
	m, err := manifest.Load(path)
	if err != nil {
		die("%v", err)
	}
	lock, err := acquireLock(m.Substrate.Namespace)
	if err != nil {
		die("%v", err)
	}
	defer lock.Close()
	prov := &provider.Linux{Name: m.Substrate.Namespace, Log: info}
	ctx := context.Background()

	switch cmd {
	case "destroy":
		if err := prov.Destroy(); err != nil {
			die("%v", err)
		}
		return
	case "up":
		runUp(ctx, m, dc, prov)
		return
	}
	inv, err := provider.Discover(ctx, m, dc)
	if err != nil {
		die("%v", err)
	}
	switch cmd {
	case "plan":
		printPlan(inv, prov)
	case "apply":
		if err := prov.Apply(inv); err != nil {
			die("%v", err)
		}
	case "status":
		printStatus(inv, prov)
	}
}

func printPlan(inv *provider.Inventory, p *provider.Linux) {
	changes := false
	fmt.Printf("ZTS plan for %s\n\n", inv.M.Path)
	if provider.NsExists(p.Name) {
		fmt.Printf("= namespace %s\n", p.Name)
	} else {
		fmt.Printf("+ namespace %s\n", p.Name)
		changes = true
	}
	for _, t := range inv.M.TransportNames() {
		if inv.M.Transports[t].Kind() == "host" {
			if p.HostlinkExists() {
				fmt.Printf("= transport %s (host link %s)\n", t, provider.HostlinkHostIf)
			} else {
				fmt.Printf("+ transport %s (host link %s)\n", t, provider.HostlinkHostIf)
				changes = true
			}
			continue
		}
		ifn := alloc.TransportIfname(t)
		if p.ZifExists(ifn) {
			fmt.Printf("= transport %s (%s)\n", t, ifn)
		} else {
			fmt.Printf("+ transport %s (%s)\n", t, ifn)
			changes = true
		}
	}
	for _, w := range inv.Workloads {
		if p.ZifExists(w.Zif) && p.ContainerEth0Matches(w) {
			fmt.Printf("= workload %-24s profile=%s ip=%s\n", w.Identity, w.Profile, w.IP)
		} else {
			fmt.Printf("~ workload %-24s profile=%s ip=%s : reconcile endpoint\n", w.Identity, w.Profile, w.IP)
			changes = true
		}
	}
	for _, s := range p.StaleEndpoints(inv) {
		fmt.Printf("- stale endpoint %s\n", s)
		changes = true
	}
	desired, current := inv.PolicyHash(), p.CurrentPolicyHash()
	if desired == current {
		fmt.Printf("= policy (routes, nftables, resolvers) %s\n", desired)
	} else {
		fmt.Printf("~ policy (routes, nftables, resolvers) %s -> %s\n", current, desired)
		changes = true
	}
	fmt.Println()
	if changes {
		fmt.Println("Plan contains changes.")
	} else {
		fmt.Println("No changes.")
	}
}

func printStatus(inv *provider.Inventory, p *provider.Linux) {
	state := "absent"
	if provider.NsExists(p.Name) {
		state = "present"
	}
	fmt.Printf("namespace: %s\nstate:     %s\npool:      %s\n", p.Name, state, inv.Pool)
	if inv.PolicyHash() == p.CurrentPolicyHash() {
		fmt.Print("policy:    converged\n\n")
	} else {
		fmt.Print("policy:    drift\n\n")
	}
	fmt.Println("workloads:")
	if len(inv.Workloads) == 0 {
		fmt.Println("  (none)")
	}
	for _, w := range inv.Workloads {
		st := "drift"
		if p.ZifExists(w.Zif) && p.ContainerEth0Matches(w) {
			st = "converged"
		}
		fmt.Printf("  %-24s profile=%-16s ip=%-15s endpoint=%-12s table=%d state=%s\n", w.Identity, w.Profile, w.IP, w.Zif, w.Table, st)
	}
	fmt.Println("\ntransports:")
	if len(inv.M.Transports) == 0 {
		fmt.Println("  (none)")
	}
	for _, t := range inv.M.TransportNames() {
		if inv.M.Transports[t].Kind() == "host" {
			st := "missing"
			if p.HostlinkExists() {
				st = "present"
			}
			fmt.Printf("  %-24s type=host      interface=%-12s state=%s\n", t, provider.HostlinkHostIf, st)
			continue
		}
		ifn := alloc.TransportIfname(t)
		st := "missing"
		if p.ZifExists(ifn) {
			st = "present"
		}
		fmt.Printf("  %-24s type=wireguard interface=%-12s state=%s\n", t, ifn, st)
	}
}

func reconcileOnce(ctx context.Context, m *manifest.Manifest, dc *docker.Client, p *provider.Linux) error {
	inv, err := provider.Discover(ctx, m, dc)
	if err != nil {
		return err
	}
	return p.Apply(inv)
}

func runUp(ctx context.Context, m *manifest.Manifest, dc *docker.Client, p *provider.Linux) {
	info("up: reconciling and watching container events (manifest: %s)", m.Path)
	// Events are requested from just before each reconcile, so a container
	// that starts while we are busy is replayed by Docker, not missed.
	since := time.Now().Unix()
	if err := reconcileOnce(ctx, m, dc, p); err != nil {
		info("warning: initial reconcile failed: %v; will retry on the next event", err)
	}
	for {
		err := dc.Events(ctx, since, func(e docker.Event) {
			info("event: %s %s", e.Action, e.Name)
			since = time.Now().Unix()
			if err := reconcileOnce(ctx, m, dc, p); err != nil {
				info("warning: reconcile failed: %v; will retry on the next event", err)
			}
		})
		info("warning: event stream closed (%v); reconnecting in 2s", err)
		time.Sleep(2 * time.Second)
	}
}

func runInit(path string, verbose bool) {
	if _, err := os.Stat(path); err == nil && os.Getenv("ZTS_FORCE") != "1" {
		info("manifest already exists: %s (set ZTS_FORCE=1 to overwrite)", path)
		return
	}
	preset := os.Getenv("ZTS_PRESET")
	if preset == "" {
		st, _ := os.Stdin.Stat()
		if st == nil || st.Mode()&os.ModeCharDevice == 0 {
			die("no TTY and ZTS_PRESET unset (coding-agent, web-dev, isolated)")
		}
		fmt.Fprint(os.Stderr, "\nWhat will these containers mostly do?\n\n")
		fmt.Fprint(os.Stderr, "  1) run coding agents   github, package registries and model APIs, port 443 only\n")
		fmt.Fprint(os.Stderr, "  2) web development     any public name on ports 80 and 443\n")
		fmt.Fprint(os.Stderr, "  3) nothing             no network at all\n\n")
		fmt.Fprint(os.Stderr, "Pick 1, 2 or 3 [1]: ")
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		switch strings.TrimSpace(line) {
		case "", "1":
			preset = "coding-agent"
		case "2":
			preset = "web-dev"
		case "3":
			preset = "isolated"
		default:
			die("pick 1, 2 or 3")
		}
	}
	text, err := manifest.Preset(preset)
	if err != nil {
		die("%v", err)
	}
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		die("%v", err)
	}
	info("wrote %s (preset: %s)", path, preset)
	if verbose {
		fmt.Println(path)
	}
}

func selftest() {
	_, pool, _ := net.ParseCIDR("100.64.0.0/10")
	gw, ip, slot, err := alloc.Endpoint("example/workload", pool)
	if err != nil || gw.Equal(ip) {
		die("selftest: endpoint allocation")
	}
	ifn := alloc.EndpointIfname("example/workload")
	wg := alloc.TransportIfname("example-egress")
	table := alloc.ProfileTable("development")
	if len(ifn) > 15 || len(wg) > 15 || table < alloc.TableMin || table >= alloc.TableMin+alloc.TableSpan {
		die("selftest: names or table out of range")
	}
	for _, n := range []string{"github.com", "*.github.com", "*"} {
		if !alloc.ValidName(n) {
			die("selftest: name rejected: %s", n)
		}
	}
	for _, n := range []string{"not a name", "localhost"} {
		if alloc.ValidName(n) {
			die("selftest: invalid name accepted: %s", n)
		}
	}
	for c, want := range map[string]bool{"192.168.1.0/24": true, "10.0.0.5/32": true, "0.0.0.0/0": false, "8.8.8.0/24": false} {
		_, n, _ := net.ParseCIDR(c)
		if alloc.CIDRIsPrivate(n) != want {
			die("selftest: private detection wrong for %s", c)
		}
	}
	for _, p := range manifest.PresetNames() {
		text, _ := manifest.Preset(p)
		tmp := filepath.Join(os.TempDir(), "zts-preset-"+p+".yaml")
		_ = os.WriteFile(tmp, []byte(text), 0o644)
		m, err := manifest.Check(tmp)
		os.Remove(tmp)
		if err != nil || len(m.Profiles["isolated"].Allow) != 0 {
			die("selftest: preset '%s' is not a valid manifest: %v", p, err)
		}
	}
	fmt.Printf("selftest ok: example/workload -> gateway=%s workload=%s slot=%d endpoint=%s wg=%s table=%d\n", gw, ip, slot, ifn, wg, table)
}
