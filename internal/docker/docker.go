// Package docker reads container inventory from the Engine API over its Unix
// socket. Read-only: ZTS never starts, stops or connects a container.
package docker

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
)

type Client struct {
	http *http.Client
	sock string
}

func New() *Client {
	sock := os.Getenv("ZTS_DOCKER_SOCK")
	if sock == "" {
		sock = "/var/run/docker.sock"
	}
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", sock)
	}}
	return &Client{http: &http.Client{Transport: tr}, sock: sock}
}

func (c *Client) Available() error {
	st, err := os.Stat(c.sock)
	if err != nil || st.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("docker socket not found: %s\n  the controller needs the host and the Docker socket; run it as:\n  docker run -d --name zts --restart unless-stopped --privileged --pid=host --network host \\\n      -v /var/run/docker.sock:/var/run/docker.sock -v zts:/etc/zts <image> up", c.sock)
	}
	return nil
}

func (c *Client) get(ctx context.Context, path string, q url.Values) (*http.Response, error) {
	u := "http://docker/" + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("docker api: %v", err)
	}
	if resp.StatusCode >= 300 {
		defer resp.Body.Close()
		return nil, fmt.Errorf("docker api %s: %s", path, resp.Status)
	}
	return resp, nil
}

// ManagedIDs lists running containers that carry the zts.profile label, sorted.
func (c *Client) ManagedIDs(ctx context.Context) ([]string, error) {
	q := url.Values{"filters": {`{"label":["zts.profile"],"status":["running"]}`}}
	resp, err := c.get(ctx, "containers/json", q)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var list []struct{ Id string }
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(list))
	for _, e := range list {
		ids = append(ids, e.Id)
	}
	sort.Strings(ids)
	return ids, nil
}

type Container struct {
	ID             string
	Name           string
	PID            int
	Running        bool
	Labels         map[string]string
	NetworkMode    string
	Privileged     bool
	ResolvConfPath string
}

func (c *Client) Inspect(ctx context.Context, id string) (*Container, error) {
	resp, err := c.get(ctx, "containers/"+id+"/json", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var j struct {
		Id    string
		Name  string
		State struct {
			Pid     int
			Running bool
		}
		Config     struct{ Labels map[string]string }
		HostConfig struct {
			NetworkMode string
			Privileged  bool
		}
		ResolvConfPath string
	}
	if err := json.NewDecoder(resp.Body).Decode(&j); err != nil {
		return nil, err
	}
	return &Container{
		ID: j.Id, Name: strings.TrimPrefix(j.Name, "/"), PID: j.State.Pid, Running: j.State.Running,
		Labels: j.Config.Labels, NetworkMode: j.HostConfig.NetworkMode, Privileged: j.HostConfig.Privileged,
		ResolvConfPath: j.ResolvConfPath,
	}, nil
}

type Event struct {
	Action string
	Name   string
}

// Events streams start/die events of labeled containers since the given Unix
// time until ctx ends or the connection closes. Docker replays events from
// `since`, so nothing that happened while the caller was busy is missed.
func (c *Client) Events(ctx context.Context, since int64, fn func(Event)) error {
	q := url.Values{
		"since":   {fmt.Sprint(since)},
		"filters": {`{"type":["container"],"event":["start","die"],"label":["zts.profile"]}`},
	}
	resp, err := c.get(ctx, "events", q)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		var e struct {
			Action string
			Actor  struct {
				ID         string
				Attributes map[string]string
			}
		}
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			continue
		}
		name := e.Actor.Attributes["name"]
		if name == "" && len(e.Actor.ID) >= 12 {
			name = e.Actor.ID[:12]
		}
		fn(Event{Action: e.Action, Name: name})
	}
	return sc.Err()
}
