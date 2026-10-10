// Package alloc derives stable names and addresses from identities, exactly
// like the bash essentials do (POSIX cksum), so both implementations agree.
package alloc

import (
	"fmt"
	"net"
	"regexp"
)

const (
	RulePref  = 10000
	TableMin  = 1000
	TableSpan = 20000
)

var crcTable = func() [256]uint32 {
	var t [256]uint32
	for i := 0; i < 256; i++ {
		c := uint32(i) << 24
		for j := 0; j < 8; j++ {
			if c&0x80000000 != 0 {
				c = c<<1 ^ 0x04C11DB7
			} else {
				c <<= 1
			}
		}
		t[i] = c
	}
	return t
}()

// Cksum is the POSIX cksum CRC: CRC-32/MSB-first over the data, then over the
// length in little-endian bytes, inverted.
func Cksum(data []byte) uint32 {
	var crc uint32
	for _, b := range data {
		crc = crc<<8 ^ crcTable[byte(crc>>24)^b]
	}
	for n := len(data); n != 0; n >>= 8 {
		crc = crc<<8 ^ crcTable[byte(crc>>24)^byte(n)]
	}
	return ^crc
}

func Hex8(s string) string { return fmt.Sprintf("%08x", Cksum([]byte(s))) }

func EndpointIfname(identity string) string { return "zt" + Hex8("endpoint:"+identity) }
func TransportIfname(name string) string    { return "wg" + Hex8("transport:"+name) }
func ResourceSetname(name string) string    { return "r_" + Hex8("resource:"+name) }
func ProfileTable(profile string) int {
	return TableMin + int(Cksum([]byte("profile:"+profile))%TableSpan)
}

// Endpoint carves a stable /30 from the pool for an identity.
// Returns gateway (host side), workload address and slot.
func Endpoint(identity string, pool *net.IPNet) (gw, ip net.IP, slot int, err error) {
	prefix, _ := pool.Mask.Size()
	if prefix > 30 {
		return nil, nil, 0, fmt.Errorf("substrate.pool must be /30 or larger")
	}
	base := ip4ToInt(pool.IP.Mask(pool.Mask))
	slots := uint32(1) << uint(30-prefix)
	slot = int(Cksum([]byte(identity)) % slots)
	n := base + uint32(slot)*4
	return intToIP4(n + 1), intToIP4(n + 2), slot, nil
}

func ip4ToInt(ip net.IP) uint32 {
	ip = ip.To4()
	return uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
}

func intToIP4(n uint32) net.IP {
	return net.IPv4(byte(n>>24), byte(n>>16), byte(n>>8), byte(n)).To4()
}

var nameRe = regexp.MustCompile(`^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$`)

// ValidName accepts "*", "*.example.com" or "example.com".
func ValidName(n string) bool {
	if n == "*" {
		return true
	}
	if len(n) > 2 && n[:2] == "*." {
		n = n[2:]
	}
	return nameRe.MatchString(n)
}

// PrivateRanges are never reachable through the host transport unless a
// resource names them explicitly.
var PrivateRanges = []string{
	"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
	"172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
}

// CIDRIsPrivate is true when the CIDR lies entirely inside a guarded range.
func CIDRIsPrivate(c *net.IPNet) bool {
	cp, _ := c.Mask.Size()
	for _, r := range PrivateRanges {
		_, rn, _ := net.ParseCIDR(r)
		rp, _ := rn.Mask.Size()
		if cp < rp {
			continue
		}
		if rn.Contains(c.IP) {
			return true
		}
	}
	return false
}
