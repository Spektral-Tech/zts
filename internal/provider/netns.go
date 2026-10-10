package provider

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"github.com/vishvananda/netns"
	"golang.org/x/sys/unix"
)

// HostRoot is where the host's filesystem is reachable when zts runs inside a
// container with --pid=host (ZTS_HOST_ROOT=/proc/1/root). Empty on a bare host.
var HostRoot = os.Getenv("ZTS_HOST_ROOT")

func netnsPath(name string) string {
	return filepath.Join(HostRoot, "/run/netns", name)
}

// NsExists reports whether the named substrate namespace is present.
func NsExists(name string) bool {
	ns, err := OpenNs(name)
	if err != nil {
		return false
	}
	ns.Close()
	return true
}

// OpenNs opens the substrate namespace. It refuses to hand back the process's
// own (host) namespace: every mutation ZTS makes assumes a namespace it owns,
// and a deny policy applied to the host would cut the host off.
func OpenNs(name string) (netns.NsHandle, error) {
	ns, err := netns.GetFromPath(netnsPath(name))
	if err != nil {
		return ns, err
	}
	cur, err := netns.Get()
	if err == nil {
		defer cur.Close()
		if ns.Equal(cur) {
			ns.Close()
			return -1, fmt.Errorf("refusing to use namespace '%s': it is the host network namespace", name)
		}
	}
	return ns, nil
}

// InNs runs fn on a thread switched into ns; the thread is discarded after.
// Sockets and child processes created inside fn belong to that namespace.
func InNs(ns netns.NsHandle, fn func() error) error {
	errc := make(chan error, 1)
	go func() {
		runtime.LockOSThread()
		// No UnlockOSThread: the thread exits with the goroutine.
		if err := netns.Set(ns); err != nil {
			errc <- fmt.Errorf("setns: %v", err)
			return
		}
		errc <- fn()
	}()
	return <-errc
}

// NsAdd creates the named namespace. On a bare host that is `ip netns add`.
// In a container it is created in the host's mount namespace (PID 1), held by
// a bind mount there, so it outlives this container.
func NsAdd(name string) error {
	if HostRoot == "" {
		return run("ip", "netns", "add", name)
	}
	if err := os.MkdirAll(filepath.Join(HostRoot, "/run/netns"), 0o755); err != nil {
		return err
	}
	errc := make(chan error, 1)
	go func() {
		runtime.LockOSThread()
		errc <- func() error {
			// Private fs state for this thread so a mount-namespace switch is allowed.
			if err := unix.Unshare(unix.CLONE_FS | unix.CLONE_NEWNET); err != nil {
				return fmt.Errorf("unshare: %v", err)
			}
			mnt, err := os.Open("/proc/1/ns/mnt")
			if err != nil {
				return err
			}
			defer mnt.Close()
			if err := unix.Setns(int(mnt.Fd()), unix.CLONE_NEWNS); err != nil {
				return fmt.Errorf("setns host mount namespace: %v", err)
			}
			target := "/run/netns/" + name
			f, err := os.OpenFile(target, os.O_CREATE|os.O_RDONLY, 0o444)
			if err != nil {
				return err
			}
			f.Close()
			// /proc/self is the thread-group leader, whose namespace did not
			// change; the unshared namespace belongs to this thread only.
			if err := unix.Mount("/proc/thread-self/ns/net", target, "", unix.MS_BIND, ""); err != nil {
				return fmt.Errorf("bind mount %s: %v", target, err)
			}
			return nil
		}()
	}()
	if err := <-errc; err != nil {
		// Fallback: the util-linux tools, when present.
		if _, lookErr := exec.LookPath("nsenter"); lookErr == nil {
			cmd := exec.Command("unshare", "-n", "--", "nsenter", "-t", "1", "-m", "-u", "-i", "--", "sh", "-c",
				fmt.Sprintf("touch /run/netns/%s && mount --bind /proc/self/ns/net /run/netns/%s", name, name))
			if out, err2 := cmd.CombinedOutput(); err2 == nil {
				return nil
			} else {
				return fmt.Errorf("%v; fallback: %v %s", err, err2, out)
			}
		}
		return err
	}
	return nil
}

// NsDel removes the named namespace; interfaces inside it (and their veth
// peers) disappear with it.
func NsDel(name string) error {
	if HostRoot == "" {
		return run("ip", "netns", "del", name)
	}
	errc := make(chan error, 1)
	go func() {
		runtime.LockOSThread()
		errc <- func() error {
			if err := unix.Unshare(unix.CLONE_FS); err != nil {
				return err
			}
			mnt, err := os.Open("/proc/1/ns/mnt")
			if err != nil {
				return err
			}
			defer mnt.Close()
			if err := unix.Setns(int(mnt.Fd()), unix.CLONE_NEWNS); err != nil {
				return err
			}
			target := "/run/netns/" + name
			_ = unix.Unmount(target, unix.MNT_DETACH)
			return os.Remove(target)
		}()
	}()
	return <-errc
}

func run(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %v: %v: %s", name, args, err, out)
	}
	return nil
}

// sysctl writes a net.* knob for the namespace of the calling thread.
func sysctl(key, val string) error {
	return os.WriteFile("/proc/sys/"+filepath.FromSlash(key), []byte(val), 0o644)
}
