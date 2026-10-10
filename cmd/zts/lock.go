package main

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// acquireLock serializes reconcilers on this host. Not a daemon or state
// service: it only keeps two one-shot applies from editing the same kernel
// objects concurrently.
func acquireLock(ns string) (*os.File, error) {
	_ = os.MkdirAll("/run/lock", 0o755)
	f, err := os.OpenFile(fmt.Sprintf("/run/lock/zts-%s.lock", ns), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}
