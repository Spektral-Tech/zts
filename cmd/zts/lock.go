package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/spektral-tech/zts/internal/provider"

	"golang.org/x/sys/unix"
)

// Locks live on the host's /run (through /proc/1/root in a container), so
// controllers and one-shot commands in different containers still exclude
// each other. Not a daemon or state service: the controller lock only says
// "a controller is running"; the reconcile lock is held while kernel state is
// read or changed and released right after.
func lockDir() string {
	dir := filepath.Join(provider.HostRoot, "/run/lock")
	_ = os.MkdirAll(dir, 0o755)
	return dir
}

// controllerLock is held for the controller's lifetime and never waits.
func controllerLock(ns string) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(lockDir(), fmt.Sprintf("zts-%s.controller", ns)), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		if err == unix.EWOULDBLOCK {
			return nil, fmt.Errorf("another controller is already running for namespace '%s' (use 'docker exec zts zts status|plan|edit' instead of a second up)", ns)
		}
		return nil, err
	}
	return f, nil
}

// reconcileLock waits a bounded time for a reconcile in progress.
func reconcileLock(ns string) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(lockDir(), fmt.Sprintf("zts-%s.lock", ns)), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			return f, nil
		}
		if err != unix.EWOULDBLOCK {
			f.Close()
			return nil, err
		}
		if time.Now().After(deadline) {
			f.Close()
			return nil, fmt.Errorf("could not get the lock for namespace '%s' within 15s (a reconcile is still running)", ns)
		}
		time.Sleep(200 * time.Millisecond)
	}
}
