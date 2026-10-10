# ZTS — Reference

How to run ZTS, what the manifest can say, and what to expect. The model is in the manifesto; the normative detail is in the spec. This page is the practical side.

## Install and first run

Only Docker is needed, on Linux or on a Mac with Docker Desktop.

```bash
docker run --rm -it -v zts:/etc/zts ghcr.io/spektral-tech/zts init
docker run -d --name zts --restart unless-stopped --privileged --pid=host --network host \
    -v /var/run/docker.sock:/var/run/docker.sock -v zts:/etc/zts ghcr.io/spektral-tech/zts up
```

`init` asks one question (coding agents, web development, or nothing) and writes `zts.yaml` into the `zts` volume. `up` starts the controller: it applies the manifest, then reacts to every container start and stop.

From then on, a managed container is any container started with `--network none` and one label:

```bash
docker run -d --name agent --network none --label zts.profile=dev alpine sleep infinity
docker exec agent wget -qO- https://api.github.com/zen
```

Why the controller container runs the way it does:

- `--privileged --pid=host`: it reaches the kernel of the Docker host. On Docker Desktop that host is Docker's own Linux VM.
- `--network host`: the host transport and the WireGuard sockets live in the host namespace.
- the Docker socket: inventory only. ZTS never starts, stops or connects a container.
- `-v zts:/etc/zts`: the manifest, and WireGuard keys if you use them.

Docker Desktop with Enhanced Container Isolation turned on blocks `--pid=host`; ZTS stops with a clear message and does not try to work around it.

## Labels

```text
zts.profile=<profile>     required: which profile of the manifest applies
zts.identity=<name>       optional: a stable identity; defaults to the container name
```

Identity decides the workload's address, which is derived from it and stable across restarts. Two running containers cannot share an identity.

## The command line

The same commands exist in the image and in the standalone binaries.

```bash
zts init     [manifest]   write a manifest from a preset; asks once on a TTY, or use ZTS_PRESET
zts check    [manifest]   validate a manifest; no root, no Docker
zts plan     [manifest]   show what apply would change; "No changes." when converged
zts apply    [manifest]   converge kernel state once and exit
zts status   [manifest]   workloads, transports, converged or drift
zts up       [manifest]   apply, then reconcile on container start/die events
zts destroy  [manifest]   remove all ZTS state; workloads fall back to no network
zts selftest              pure checks: allocation, names, presets
```

The manifest defaults to `/etc/zts/zts.yaml` when that directory exists, else `./zts.yaml`.

Through the image:

```bash
docker exec zts zts status
docker exec zts zts plan
docker restart zts                  # re-read the manifest now
docker logs zts                     # every event and reconciliation
docker run --rm --privileged --pid=host --network host \
    -v /var/run/docker.sock:/var/run/docker.sock -v zts:/etc/zts ghcr.io/spektral-tech/zts destroy
```

## zts.yaml

```yaml
version: 1

substrate:
  namespace: zts                    # the Linux namespace ZTS owns
  pool: 100.64.0.0/10               # addresses for workloads; a /30 per identity
  resolvers: [1.1.1.1, 9.9.9.9]     # upstream DNS for name-based resources

transports:
  host:
    type: host                      # leave through this host's default route
    allow_private: false            # keep private, link-local and multicast unreachable
  sandbox-egress:
    type: wireguard
    address: 10.255.255.2/32
    private_key_file: /etc/zts/sandbox-egress.key
    peer:
      public_key: ...
      endpoint: 192.0.2.10:51820
      allowed_ips: [0.0.0.0/0]
      persistent_keepalive: 25

resources:
  accounting-db:
    workload: accounting-db         # another managed container on this host
  github:
    names: [github.com, "*.github.com", "*.githubusercontent.com"]
  internet:
    cidrs: [0.0.0.0/0]
  office-printer:
    cidrs: [192.168.1.40/32]

profiles:
  isolated:
    allow: []
  dev:
    allow:
      - { to: accounting-db, protocol: tcp, ports: [5432] }
      - { to: github,        via: host, protocol: tcp, ports: [443] }
```

### substrate

`namespace` names the Linux network namespace that holds every ZTS object. `pool` is carved into one /30 per identity, derived from the identity's hash, so there is no state file. `resolvers` are reached through the host transport.

### transports

A transport is a way out. Declaring one grants nothing; a profile has to name it.

- `host`: NAT through the host's own default route. Private (`10/8`, `172.16/12`, `192.168/16`), carrier-grade (`100.64/10`), loopback, link-local and multicast destinations are dropped unless a resource declares a CIDR inside one of those ranges, or `allow_private: true`. `0.0.0.0/0` does not count as declaring private space. This is also what stops DNS rebinding.
- `wireguard`: an authenticated tunnel to a remote gateway. The interface is created on the host and moved into the namespace, so its UDP socket keeps the host's underlay while plaintext exists only inside ZTS. The remote peer must route the pool back through the tunnel.

### resources

A resource is a logical destination.

- `workload`: another managed container, by identity. No `via`: it is local.
- `cidrs`: IPv4 ranges. Needs `via`.
- `names`: DNS names. A name covers its subdomains; `"*"` means any name. Needs `via`. All name-based resources of one profile must use the same transport.

How names work without a proxy: the workload's only DNS server is its gateway. For each profile, that resolver answers only declared names and feeds the addresses it returns into a kernel set that the forwarding policy references. Undeclared names get NXDOMAIN. A raw address that was never returned for a declared name has no path. TLS stays end to end; there is no certificate to install and no environment variable to set.

### profiles

A profile is a list of `allow` relations:

```yaml
- { to: <resource>, via: <transport>, protocol: tcp|udp|any, ports: [..] }
```

`via` is required for CIDR and name resources, forbidden for workload resources. `ports` require `tcp` or `udp`. An empty `allow` is a workload with no network.

## Scenarios

**A coding agent that may reach GitHub, package registries and model APIs, port 443 only.** The `coding-agent` preset. Everything else, including the host and the LAN, is unreachable.

**Web development: any public name, web ports only.** The `web-dev` preset: `names: ["*"]` via host on 80 and 443. Host, LAN and link-local stay closed.

**Two workloads that talk to each other, nothing else.**

```yaml
resources:
  db: { workload: db }
profiles:
  app:
    allow:
      - { to: db, protocol: tcp, ports: [5432] }
  db:
    allow: []
```

Start `db` with `--label zts.profile=db` and the app with `--label zts.profile=app`. The relation is one-way: `db` cannot open connections to the app.

**One LAN device, explicitly.**

```yaml
resources:
  printer: { cidrs: [192.168.1.40/32] }
profiles:
  print:
    allow:
      - { to: printer, via: host, protocol: tcp, ports: [9100] }
```

The private-space guard lets this through because the CIDR lies entirely inside private space and was named on purpose.

**Everything through a remote gateway.** Declare a `wireguard` transport and use `via: <its name>` on `internet` or on name-based resources. The gateway sees only that tunnel, never your LAN.

**Something that must stay offline.** `isolated` is in every preset: `allow: []`. The container has `lo` and an `eth0` that leads nowhere.

## What to expect

- A container's process starts together with its network namespace; the controller attaches on the `start` event a moment later, typically under a second. Long-running workloads never notice. A one-shot `docker run ... wget` can race that moment: prove things with `docker exec`, or let the command retry.
- `docker inspect` keeps reporting `NetworkMode=none`. Docker is inventory, not authority.
- Stopping the controller leaves kernel state, routes and already-resolved names in place. In the Go core, the resolvers are separate processes and keep answering; in the bash essentials they stop with the controller.
- `destroy` removes the namespace and everything in it. Workloads fall back to no network.
- Inspect the native state yourself: `nsenter --net=/run/netns/zts nft list ruleset`, `ip -n zts route show table <n>`, `ip -n zts rule`. The controller is not in the packet path; those objects are the whole mechanism.

## Running without the image

### Go core

```bash
go build -o bin/zts ./cmd/zts
./bin/zts check zts.yaml
sudo ./bin/zts apply zts.yaml
```

Needs `nft` on the host, and `iptables` when Docker manages the host firewall (ZTS opens Docker's `DOCKER-USER` chain for its link).

### Bash essentials

`zts.sh` is the readable reference: one file that does the most with the least. It is kept in parity with the Go core and passes the same acceptance suite.

Dependencies: bash 4+, curl, jq, Mike Farah `yq` v4, iproute2, nftables, `nsenter`, `flock`; `dnsmasq` built with nftset support for name-based resources; `wireguard-tools` for WireGuard transports.

```bash
./zts.sh selftest
./zts.sh check zts.yaml
sudo ./zts.sh apply zts.yaml
sudo ./zts.sh status zts.yaml
sudo ./zts.sh up zts.yaml
```

Read it top to bottom; every kernel object it creates is named there. `Dockerfile.bash` packages it with its tools, including a dnsmasq compiled with nftset.

## Verifying a checkout

```bash
scripts/run-checks.sh            # lint, selftests, fixtures, go test, site; acceptance when root+nft+docker
sudo tests/acceptance/run.sh     # the spec's acceptance tests plus names, on Linux
scripts/two-minutes.sh           # the quickstart, timed, with a host-namespace cleanliness check
```

The acceptance suite runs against either implementation: `ZTS_BIN=./bin/zts tests/acceptance/run.sh`.
