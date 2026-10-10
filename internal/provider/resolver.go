package provider

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/miekg/dns"
	"github.com/vishvananda/netns"
)

// RunDir holds resolver configs and pid files.
const RunDir = "/run/zts"

// ResolverSpec is what a detached resolver process reads at start.
type ResolverSpec struct {
	Namespace string         `json:"namespace"`
	Config    ResolverConfig `json:"config"`
	Upstreams []string       `json:"upstreams"`
}

// Resolver answers DNS for the workloads of one profile. It listens on each
// workload's gateway address inside the substrate namespace, forwards only
// declared names to the upstream resolvers, feeds the answers into the nft
// set of the matching resource, and returns NXDOMAIN for anything else.
//
// It runs as its own process (`zts resolver <spec.json>`), detached from the
// reconciler, so a one-shot apply leaves it behind and it outlives the
// controller.
type Resolver struct {
	cfg       ResolverConfig
	upstreams []string
	servers   []*dns.Server
	conns     []*dns.Conn
	mu        sync.Mutex
	ns        netns.NsHandle
}

func specPath(profile string) string { return filepath.Join(RunDir, "resolver-"+profile+".json") }
func pidPath(profile string) string  { return filepath.Join(RunDir, "resolver-"+profile+".pid") }

func readPid(profile string) int {
	b, err := os.ReadFile(pidPath(profile))
	if err != nil {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	if pid <= 0 || syscall.Kill(pid, 0) != nil {
		return 0
	}
	return pid
}

func stopResolver(profile string) {
	if pid := readPid(profile); pid > 0 {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	_ = os.Remove(pidPath(profile))
	_ = os.Remove(specPath(profile))
}

// ApplyResolvers converges the detached resolver processes to the desired set.
func ApplyResolvers(nsName string, cfgs []ResolverConfig, upstreams []string) error {
	if err := os.MkdirAll(RunDir, 0o755); err != nil {
		return err
	}
	want := map[string]bool{}
	for _, c := range cfgs {
		want[c.Profile] = true
		spec := ResolverSpec{Namespace: nsName, Config: c, Upstreams: upstreams}
		b, _ := json.Marshal(spec)
		if old, err := os.ReadFile(specPath(c.Profile)); err == nil && string(old) == string(b) && readPid(c.Profile) > 0 {
			continue
		}
		stopResolver(c.Profile)
		if err := os.WriteFile(specPath(c.Profile), b, 0o644); err != nil {
			return err
		}
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		cmd := exec.Command(exe, "resolver", specPath(c.Profile))
		cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("profile '%s': resolver: %v", c.Profile, err)
		}
		if err := os.WriteFile(pidPath(c.Profile), []byte(strconv.Itoa(cmd.Process.Pid)), 0o644); err != nil {
			return err
		}
		_ = cmd.Process.Release()
	}
	entries, _ := filepath.Glob(filepath.Join(RunDir, "resolver-*.pid"))
	for _, e := range entries {
		p := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(e), "resolver-"), ".pid")
		if !want[p] {
			stopResolver(p)
		}
	}
	return nil
}

// StopResolvers kills every detached resolver.
func StopResolvers() {
	entries, _ := filepath.Glob(filepath.Join(RunDir, "resolver-*.pid"))
	for _, e := range entries {
		p := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(e), "resolver-"), ".pid")
		stopResolver(p)
	}
}

// ServeResolver is the entry point of the detached process.
func ServeResolver(specFile string) error {
	b, err := os.ReadFile(specFile)
	if err != nil {
		return err
	}
	var spec ResolverSpec
	if err := json.Unmarshal(b, &spec); err != nil {
		return err
	}
	ns, err := OpenNs(spec.Namespace)
	if err != nil {
		return err
	}
	defer ns.Close()
	r := &Resolver{cfg: spec.Config, upstreams: spec.Upstreams, ns: ns}
	if err := r.start(ns); err != nil {
		return err
	}
	select {}
}

func (r *Resolver) start(ns netns.NsHandle) error {
	return InNs(ns, func() error {
		// Upstream connections are created here so they live in the substrate
		// namespace and leave through the host transport.
		for _, u := range r.upstreams {
			c, err := net.Dial("udp", net.JoinHostPort(u, "53"))
			if err != nil {
				return err
			}
			r.conns = append(r.conns, &dns.Conn{Conn: c})
		}
		for _, ip := range r.cfg.Listen {
			addr := net.JoinHostPort(ip.String(), "53")
			pc, err := net.ListenPacket("udp", addr)
			if err != nil {
				return err
			}
			l, err := net.Listen("tcp", addr)
			if err != nil {
				return err
			}
			for _, srv := range []*dns.Server{{PacketConn: pc, Handler: r}, {Listener: l, Handler: r}} {
				r.servers = append(r.servers, srv)
				go func(s *dns.Server) { _ = s.ActivateAndServe() }(srv)
			}
		}
		return nil
	})
}

// setFor returns the nft set a name belongs to ("" when not declared).
// A declared name covers itself and its subdomains; longest match wins.
func (r *Resolver) setFor(qname string) (string, bool) {
	q := strings.TrimSuffix(strings.ToLower(qname), ".")
	best, set := -1, ""
	for domain, s := range r.cfg.Sets {
		if q == domain || strings.HasSuffix(q, "."+domain) {
			if len(domain) > best {
				best, set = len(domain), s
			}
		}
	}
	if best >= 0 {
		return set, true
	}
	return "", r.cfg.Any
}

func (r *Resolver) ServeDNS(w dns.ResponseWriter, req *dns.Msg) {
	resp := new(dns.Msg)
	resp.SetReply(req)
	if len(req.Question) != 1 {
		resp.Rcode = dns.RcodeRefused
		_ = w.WriteMsg(resp)
		return
	}
	set, ok := r.setFor(req.Question[0].Name)
	if !ok {
		resp.Rcode = dns.RcodeNameError
		_ = w.WriteMsg(resp)
		return
	}
	up, err := r.forward(req)
	if err != nil {
		resp.Rcode = dns.RcodeServerFailure
		_ = w.WriteMsg(resp)
		return
	}
	if set != "" {
		var elems []string
		for _, rr := range up.Answer {
			if a, ok := rr.(*dns.A); ok {
				ttl := int(a.Hdr.Ttl)
				if ttl < 60 {
					ttl = 60
				}
				elems = append(elems, fmt.Sprintf("%s timeout %ds", a.A, ttl))
			}
		}
		if len(elems) > 0 {
			// The table lives in the substrate namespace; handler goroutines do
			// not. Existing elements are left alone; expired ones come back.
			_ = InNs(r.ns, func() error {
				return exec.Command("nft", "add", "element", "inet", "zts", set, "{ "+strings.Join(elems, ", ")+" }").Run()
			})
		}
	}
	up.Id = req.Id
	_ = w.WriteMsg(up)
}

func (r *Resolver) forward(req *dns.Msg) (*dns.Msg, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	c := &dns.Client{Timeout: 3 * time.Second}
	var last error
	for _, conn := range r.conns {
		resp, _, err := c.ExchangeWithConn(req, conn)
		if err == nil {
			return resp, nil
		}
		last = err
	}
	return nil, last
}
