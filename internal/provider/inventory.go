// Package provider materializes a manifest as Linux network state.
package provider

import (
	"context"
	"fmt"
	"net"
	"regexp"

	"github.com/spektral-tech/zts/internal/alloc"
	"github.com/spektral-tech/zts/internal/docker"
	"github.com/spektral-tech/zts/internal/manifest"
	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

var (
	identityRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_./-]{0,63}$`)
	// Kernels with built-in tunnel drivers drop fallback devices into every
	// new netns; they carry no path.
	benignIfRe = regexp.MustCompile(`^(lo|eth0|tunl0|gre0|gretap0|erspan0|ip6tnl0|ip6gre0|ip6gretap0|ip6erspan0|sit0|ip_vti0|ip6_vti0|dummy0|teql0|ifb[0-9]+|bond0|nlmon0)$`)
)

type Workload struct {
	Identity   string
	CID        string
	PID        int
	Profile    string
	GW, IP     net.IP
	Slot       int
	Zif        string
	ResolvPath string
	Table      int
}

// Inventory is the desired state: manifest plus discovered workloads.
type Inventory struct {
	M                *manifest.Manifest
	Pool             *net.IPNet
	Workloads        []*Workload
	Profiles         []string // order of first appearance
	Table            map[string]int
	NameVia          map[string]string // profile -> transport carrying its names
	HostName         string            // name of the host transport ("" if none)
	HostAllowPrivate bool
}

func (inv *Inventory) byIdentity(id string) *Workload {
	for _, w := range inv.Workloads {
		if w.Identity == id {
			return w
		}
	}
	return nil
}

func (inv *Inventory) workloadsOf(profile string) []*Workload {
	var out []*Workload
	for _, w := range inv.Workloads {
		if w.Profile == profile {
			out = append(out, w)
		}
	}
	return out
}

// Discover reads labeled running containers and validates the desired graph.
func Discover(ctx context.Context, m *manifest.Manifest, dc *docker.Client) (*Inventory, error) {
	pool, err := m.Pool()
	if err != nil {
		return nil, err
	}
	inv := &Inventory{M: m, Pool: pool, Table: map[string]int{}, NameVia: map[string]string{}}
	if n, t := m.HostTransport(); t != nil {
		inv.HostName = n
		inv.HostAllowPrivate = t.AllowPrivate
	}
	ids, err := dc.ManagedIDs(ctx)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	bySlot := map[int]string{}
	byTable := map[int]string{}
	for _, cid := range ids {
		c, err := dc.Inspect(ctx, cid)
		if err != nil {
			return nil, err
		}
		if !c.Running {
			continue
		}
		profile := c.Labels["zts.profile"]
		identity := c.Labels["zts.identity"]
		if identity == "" {
			identity = c.Name
		}
		if profile == "" {
			return nil, fmt.Errorf("%s: missing zts.profile label", c.Name)
		}
		if !identityRe.MatchString(identity) {
			return nil, fmt.Errorf("%s: invalid identity '%s'", c.Name, identity)
		}
		if c.NetworkMode != "none" {
			return nil, fmt.Errorf("%s: Docker NetworkMode must be 'none' (got '%s')", identity, c.NetworkMode)
		}
		if c.Privileged {
			return nil, fmt.Errorf("%s: privileged containers are not accepted", identity)
		}
		if _, ok := m.Profiles[profile]; !ok {
			return nil, fmt.Errorf("%s: unknown profile '%s'", identity, profile)
		}
		if seen[identity] {
			return nil, fmt.Errorf("duplicate running identity '%s'", identity)
		}
		seen[identity] = true
		if c.PID <= 0 {
			return nil, fmt.Errorf("%s: container has no PID", identity)
		}
		gw, ip, slot, err := alloc.Endpoint(identity, pool)
		if err != nil {
			return nil, err
		}
		if other, ok := bySlot[slot]; ok && other != identity {
			return nil, fmt.Errorf("address allocation collision: '%s' and '%s' map to slot %d", identity, other, slot)
		}
		bySlot[slot] = identity
		if err := checkContainerInterfaces(c.PID, identity); err != nil {
			return nil, err
		}
		table := alloc.ProfileTable(profile)
		if other, ok := byTable[table]; ok && other != profile {
			return nil, fmt.Errorf("routing-table hash collision: profiles '%s' and '%s'", profile, other)
		}
		if _, ok := inv.Table[profile]; !ok {
			inv.Profiles = append(inv.Profiles, profile)
			inv.Table[profile] = table
		}
		byTable[table] = profile
		inv.Workloads = append(inv.Workloads, &Workload{
			Identity: identity, CID: cid, PID: c.PID, Profile: profile, GW: gw, IP: ip, Slot: slot,
			Zif: alloc.EndpointIfname(identity), ResolvPath: c.ResolvConfPath, Table: table,
		})
	}
	running := map[string]bool{}
	for _, w := range inv.Workloads {
		running[w.Identity] = true
	}
	for _, p := range inv.Profiles {
		via, err := m.ValidateProfile(p, running)
		if err != nil {
			return nil, err
		}
		if via != "" {
			inv.NameVia[p] = via
		}
	}
	return inv, nil
}

// With --network none, only lo is expected before ZTS; eth0 is accepted as
// already materialized ZTS state.
func checkContainerInterfaces(pid int, identity string) error {
	ns, err := netns.GetFromPid(pid)
	if err != nil {
		return fmt.Errorf("%s: cannot open container netns: %v", identity, err)
	}
	defer ns.Close()
	h, err := netlink.NewHandleAt(ns)
	if err != nil {
		return err
	}
	defer h.Close()
	links, err := h.LinkList()
	if err != nil {
		return err
	}
	for _, l := range links {
		if !benignIfRe.MatchString(l.Attrs().Name) {
			return fmt.Errorf("%s: unexpected interface '%s' exists inside container netns", identity, l.Attrs().Name)
		}
	}
	return nil
}
