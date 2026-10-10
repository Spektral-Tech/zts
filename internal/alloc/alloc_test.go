package alloc

import (
	"net"
	"testing"
)

// Golden values come from the bash essentials (`zts.sh selftest`), which use
// POSIX cksum. Both implementations must agree on every derived name.
func TestParityWithBash(t *testing.T) {
	_, pool, _ := net.ParseCIDR("100.64.0.0/10")
	gw, ip, slot, err := Endpoint("example/workload", pool)
	if err != nil {
		t.Fatal(err)
	}
	if gw.String() != "100.84.182.65" || ip.String() != "100.84.182.66" || slot != 339344 {
		t.Fatalf("endpoint: got %s %s %d", gw, ip, slot)
	}
	if got := EndpointIfname("example/workload"); got != "zt1a30bd15" {
		t.Fatalf("ifname: %s", got)
	}
	if got := TransportIfname("example-egress"); got != "wg7ca1d1ae" {
		t.Fatalf("wg ifname: %s", got)
	}
	if got := ProfileTable("development"); got != 14482 {
		t.Fatalf("table: %d", got)
	}
}

func TestCksumKnownVector(t *testing.T) {
	// `printf 'abc' | cksum` -> 1219131554
	if got := Cksum([]byte("abc")); got != 1219131554 {
		t.Fatalf("cksum(abc) = %d", got)
	}
}

func TestNames(t *testing.T) {
	for _, ok := range []string{"github.com", "*.github.com", "*", "a.b.c.example.io"} {
		if !ValidName(ok) {
			t.Errorf("rejected %q", ok)
		}
	}
	for _, bad := range []string{"not a name", "localhost", "*.", "-x.com", "x.-com"} {
		if ValidName(bad) {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestPrivate(t *testing.T) {
	cases := map[string]bool{
		"192.168.1.0/24": true, "10.0.0.5/32": true, "100.64.0.0/10": true, "169.254.100.1/32": true,
		"0.0.0.0/0": false, "8.8.8.0/24": false, "1.1.1.1/32": false, "172.15.0.0/16": false, "172.16.0.0/12": true,
	}
	for c, want := range cases {
		_, n, _ := net.ParseCIDR(c)
		if CIDRIsPrivate(n) != want {
			t.Errorf("%s: want %v", c, want)
		}
	}
}
