// Package manifest loads and validates the desired-state manifest.
package manifest

import (
	"fmt"
	"net"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/spektral-tech/zts/internal/alloc"
	"gopkg.in/yaml.v3"
)

type Manifest struct {
	Version    int                  `yaml:"version"`
	Substrate  Substrate            `yaml:"substrate"`
	Transports map[string]Transport `yaml:"transports"`
	Resources  map[string]Resource  `yaml:"resources"`
	Profiles   map[string]Profile   `yaml:"profiles"`

	Path string `yaml:"-"`
}

type Substrate struct {
	Namespace string   `yaml:"namespace"`
	Pool      string   `yaml:"pool"`
	Resolvers []string `yaml:"resolvers"`
}

type Transport struct {
	Type           string `yaml:"type"`
	AllowPrivate   bool   `yaml:"allow_private"`
	Address        string `yaml:"address"`
	PrivateKeyFile string `yaml:"private_key_file"`
	Peer           *Peer  `yaml:"peer"`
}

type Peer struct {
	PublicKey           string   `yaml:"public_key"`
	Endpoint            string   `yaml:"endpoint"`
	AllowedIPs          []string `yaml:"allowed_ips"`
	PersistentKeepalive int      `yaml:"persistent_keepalive"`
}

type Resource struct {
	Workload string   `yaml:"workload"`
	CIDRs    []string `yaml:"cidrs"`
	Names    []string `yaml:"names"`
}

type Profile struct {
	Allow []Allow `yaml:"allow"`
}

type Allow struct {
	To       string `yaml:"to"`
	Via      string `yaml:"via"`
	Protocol string `yaml:"protocol"`
	Ports    []int  `yaml:"ports"`
}

var (
	nsRe   = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,15}$`)
	nameRe = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,32}$`)
)

// Load parses and validates the manifest-level rules (SPEC §13). Unknown keys
// are rejected at every level.
func Load(path string) (*Manifest, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("manifest not found: %s (run 'zts init' first, or set ZTS_PRESET)", path)
		}
		return nil, err
	}
	m := &Manifest{Path: path}
	dec := yaml.NewDecoder(strings.NewReader(string(b)))
	dec.KnownFields(true)
	if err := dec.Decode(m); err != nil {
		return nil, fmt.Errorf("manifest: %v", err)
	}
	if m.Version != 1 {
		return nil, fmt.Errorf("manifest version must be 1")
	}
	if m.Substrate.Namespace == "" {
		m.Substrate.Namespace = "zts"
	}
	if !nsRe.MatchString(m.Substrate.Namespace) {
		return nil, fmt.Errorf("invalid substrate.namespace: %s", m.Substrate.Namespace)
	}
	if m.Substrate.Pool == "" {
		m.Substrate.Pool = "100.64.0.0/10"
	}
	pool, err := m.Pool()
	if err != nil {
		return nil, fmt.Errorf("invalid substrate.pool: %s", m.Substrate.Pool)
	}
	if p, _ := pool.Mask.Size(); p > 30 {
		return nil, fmt.Errorf("substrate.pool must be /30 or larger")
	}
	if len(m.Substrate.Resolvers) == 0 {
		m.Substrate.Resolvers = []string{"1.1.1.1", "9.9.9.9"}
	}
	for _, r := range m.Substrate.Resolvers {
		if ip := net.ParseIP(r); ip == nil || ip.To4() == nil {
			return nil, fmt.Errorf("invalid substrate.resolvers entry: %s", r)
		}
	}
	hosts := 0
	for _, t := range m.TransportNames() {
		tr := m.Transports[t]
		if !nameRe.MatchString(t) {
			return nil, fmt.Errorf("invalid transport name: %s", t)
		}
		switch tr.Kind() {
		case "host":
			hosts++
			if hosts > 1 {
				return nil, fmt.Errorf("only one transport of type=host is supported")
			}
		case "wireguard":
			if _, _, err := net.ParseCIDR(tr.Address); err != nil {
				return nil, fmt.Errorf("transport '%s': invalid address '%s'", t, tr.Address)
			}
			if tr.PrivateKeyFile == "" {
				return nil, fmt.Errorf("transport '%s': private_key_file is required", t)
			}
			if tr.Peer == nil || tr.Peer.PublicKey == "" {
				return nil, fmt.Errorf("transport '%s': peer.public_key is required", t)
			}
			if tr.Peer.Endpoint == "" {
				return nil, fmt.Errorf("transport '%s': peer.endpoint is required", t)
			}
			if tr.Peer.PersistentKeepalive < 0 || tr.Peer.PersistentKeepalive > 65535 {
				return nil, fmt.Errorf("transport '%s': persistent_keepalive out of range", t)
			}
			if len(tr.Peer.AllowedIPs) == 0 {
				return nil, fmt.Errorf("transport '%s': peer.allowed_ips cannot be empty", t)
			}
			for _, a := range tr.Peer.AllowedIPs {
				if _, _, err := net.ParseCIDR(a); err != nil {
					return nil, fmt.Errorf("transport '%s': invalid allowed_ip '%s'", t, a)
				}
			}
		default:
			return nil, fmt.Errorf("transport '%s': unsupported type '%s' (host, wireguard)", t, tr.Type)
		}
	}
	return m, nil
}

func (t Transport) Kind() string {
	if t.Type == "" {
		return "wireguard"
	}
	return t.Type
}

func (m *Manifest) Pool() (*net.IPNet, error) {
	_, n, err := net.ParseCIDR(m.Substrate.Pool)
	return n, err
}

func (m *Manifest) TransportNames() []string { return sortedKeys(m.Transports) }
func (m *Manifest) ProfileNames() []string   { return sortedKeys(m.Profiles) }

func (m *Manifest) HostTransport() (string, *Transport) {
	for _, t := range m.TransportNames() {
		tr := m.Transports[t]
		if tr.Kind() == "host" {
			return t, &tr
		}
	}
	return "", nil
}

func (r Resource) HasNames() bool { return len(r.Names) > 0 }
func (r Resource) AnyName() bool {
	for _, n := range r.Names {
		if n == "*" {
			return true
		}
	}
	return false
}

func (a Allow) Proto() string {
	if a.Protocol == "" {
		return "any"
	}
	return a.Protocol
}

// ValidateProfile checks one profile's relations. running, when non-nil,
// must contain every workload identity a workload resource may point at.
// It returns the transport used by the profile's name-based resources ("" if none).
func (m *Manifest) ValidateProfile(name string, running map[string]bool) (string, error) {
	p, ok := m.Profiles[name]
	if !ok {
		return "", fmt.Errorf("unknown profile '%s'", name)
	}
	nameVia := ""
	for i, a := range p.Allow {
		if a.To == "" {
			return "", fmt.Errorf("profile '%s': allow[%d].to is required", name, i)
		}
		r, ok := m.Resources[a.To]
		if !ok {
			return "", fmt.Errorf("profile '%s': unknown resource '%s'", name, a.To)
		}
		switch a.Proto() {
		case "any", "tcp", "udp":
		default:
			return "", fmt.Errorf("profile '%s': allow[%d] invalid protocol '%s'", name, i, a.Protocol)
		}
		if len(a.Ports) > 0 && a.Proto() == "any" {
			return "", fmt.Errorf("profile '%s': ports require protocol tcp or udp", name)
		}
		for _, port := range a.Ports {
			if port < 1 || port > 65535 {
				return "", fmt.Errorf("profile '%s': port '%d' out of range", name, port)
			}
		}
		if r.Workload != "" {
			if running != nil && !running[r.Workload] {
				return "", fmt.Errorf("resource '%s': workload '%s' is not running/managed", a.To, r.Workload)
			}
			if a.Via != "" {
				return "", fmt.Errorf("profile '%s': workload resource '%s' cannot use via='%s'", name, a.To, a.Via)
			}
			continue
		}
		for _, c := range r.CIDRs {
			if _, _, err := net.ParseCIDR(c); err != nil {
				return "", fmt.Errorf("resource '%s': invalid cidr '%s'", a.To, c)
			}
		}
		for _, n := range r.Names {
			if !alloc.ValidName(n) {
				return "", fmt.Errorf("resource '%s': invalid name '%s'", a.To, n)
			}
		}
		if len(r.CIDRs) == 0 && len(r.Names) == 0 {
			return "", fmt.Errorf("resource '%s': define workload, cidrs or names", a.To)
		}
		if a.Via == "" {
			return "", fmt.Errorf("profile '%s': resource '%s' requires via=<transport>", name, a.To)
		}
		if _, ok := m.Transports[a.Via]; !ok {
			return "", fmt.Errorf("profile '%s': unknown transport '%s'", name, a.Via)
		}
		if r.HasNames() {
			if nameVia != "" && nameVia != a.Via {
				return "", fmt.Errorf("profile '%s': name-based resources must all use the same transport (got '%s' and '%s')", name, nameVia, a.Via)
			}
			nameVia = a.Via
		}
	}
	return nameVia, nil
}

// Check validates every profile without root, Docker or kernel access.
func Check(path string) (*Manifest, error) {
	m, err := Load(path)
	if err != nil {
		return nil, err
	}
	if len(m.Profiles) == 0 {
		return nil, fmt.Errorf("manifest declares no profiles")
	}
	for _, p := range m.ProfileNames() {
		if !nameRe.MatchString(p) {
			return nil, fmt.Errorf("invalid profile name: %s", p)
		}
		if _, err := m.ValidateProfile(p, nil); err != nil {
			return nil, err
		}
	}
	return m, nil
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
