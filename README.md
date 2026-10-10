# ZTS

Status: v0.1.1 pre-release · License: Apache-2.0

ZTS gives any unmodified container only the network paths its profile declares. By name, by port, by transport. No proxy, no SDK, no CA, no ambient trust. Everything else is unreachable by construction.

Site and docs: https://spektral-tech.github.io/zts/

## In short

**What it does**

- Nothing by default: a managed container has no LAN, no host, no internet, no other containers. Every path exists because the manifest declared it.
- Names without a proxy: allow `github.com`, not an IP list. The container's own resolver answers only declared names and the answer becomes the authorization. No CA, no environment variable, TLS end to end.
- Any image, unchanged: `--network none` and one label. The application sees an ordinary `eth0`.
- Relations by resource, transport, protocol and ports, including container-to-container on the same host, one-way.
- Egress through the host's own route, with private and link-local space guarded, or through WireGuard to a remote gateway.
- Nothing in the packet path: policy is compiled into namespaces, routes and nftables; the controller wakes up only on container start and stop. Inspect it with `nft` and `ip`.
- One `docker run`, Linux or Mac with Docker Desktop. The host installs nothing.
- A Go core and a one-file bash reference pass the same acceptance suite.

**Who it is for**

- You run coding agents: an agent with a shell and your tokens should reach GitHub and the model API, and nothing else on your machine or network.
- You run code you did not write: third-party tools, build steps, evaluation jobs.
- You give workloads credentials and want the network, not the application, to bound what a leak can do.
- You have `docker run`, not a cluster: network policy for a laptop, a home server or a single VM, without Kubernetes, a mesh or a proxy per app.

**When you need it**

- An agent, a scraper or a notebook needs the internet but your home or office network must stay invisible to it.
- A CI or build job must reach the package registry and nothing else.
- A service must only talk to its database, and the database must only hear from that service.
- You want to prove, not promise, that a container cannot reach the LAN.

**When you do not**

- Kubernetes: use its network policies or a CNI that enforces them.
- HTTP-level rules (methods, paths): that is a proxy's job. ZTS can route a workload to one; it does not replace it.
- IPv6-only, Windows containers, Podman: not yet.

**How it differs.** Agent sandboxes filter through an HTTP proxy, so the application must honor `HTTP_PROXY` and only TLS on 443 is covered. Meshes and VPN ACLs authorize hosts, tags or subnets, so every container on a host inherits the same reach. ZTS authorizes per container at the network layer, by name, port and transport, for any protocol, with no proxy and nothing in the packet path.

- `MANIFESTO.md` — the model in plain language
- `SPEC.md` — technical specification
- `REFERENCE.md` — how to use it: install, command line, `zts.yaml`, scenarios
- `cmd/`, `internal/` — the Go core: one static binary, the controller image (`Dockerfile`)
- `zts.sh` — bash essentials: the readable reference implementation, kept in parity (`Dockerfile.bash`)
- `zts.example.yaml` — example manifest
- `web/` — the site as JSX components (Preact, rendered to static HTML at build time); `site/` is the committed build output, checked by `run-checks`
- `docs/` — vision, slices, decisions, evals
- `tests/` — manifest fixtures and the Linux acceptance suite
- `scripts/` — `run-checks.sh` (the single verification), `two-minutes.sh`, `lab-vm.sh`

## Two minutes, only Docker

```bash
docker run --rm -it -v zts:/etc/zts ghcr.io/spektral-tech/zts init
docker run -d --name zts --restart unless-stopped --privileged --pid=host --network host \
    -v /var/run/docker.sock:/var/run/docker.sock -v zts:/etc/zts ghcr.io/spektral-tech/zts up
docker run -d --name agent --network none --label zts.profile=dev alpine sleep infinity
docker exec agent wget -qO- https://api.github.com/zen
```

The manifest lives in the `zts` volume. Change it with `zts edit` (opens `$EDITOR`, saves only a valid result) or `zts show` / `zts load` for your own editor; the running controller applies a changed manifest within two seconds and keeps the previous state if the new one is invalid.

A container's process starts together with its network namespace, and the controller attaches on the `start` event a moment later. Long-running workloads never notice; a one-shot `docker run ... wget` can race that moment, so prove things with `docker exec` or let the command retry.

Build the image yourself: `docker build -t zts .` (Go core, ~29 MB) or `docker build -f Dockerfile.bash -t zts .` (bash essentials) and use `zts` in place of `ghcr.io/spektral-tech/zts`. Both pass the same acceptance suite.

## On a Linux host, without the image

Go core (needs only `nft`, plus `iptables` when Docker manages the host firewall):

```bash
go build -o bin/zts ./cmd/zts
./bin/zts check zts.example.yaml
sudo ./bin/zts apply zts.example.yaml
sudo ./bin/zts status zts.example.yaml
```

Bash essentials (bash 4+, curl, jq, Mike Farah `yq` v4, iproute2, nftables, `nsenter`, `flock`; `dnsmasq` for names; `wireguard-tools` for WireGuard):

```bash
./zts.sh selftest
./zts.sh check zts.example.yaml
sudo ./zts.sh apply zts.example.yaml
sudo ./zts.sh status zts.example.yaml
```

The two agree on every derived name and address (`scripts/run-checks.sh` diffs their selftests), and the acceptance suite runs against either: `ZTS_BIN=./bin/zts tests/acceptance/run.sh`.

## Verify

```bash
scripts/run-checks.sh          # lint, selftests, fixtures, go test, site; acceptance when root+nft+docker
sudo tests/acceptance/run.sh   # the SPEC §17 tests plus names, on Linux
scripts/two-minutes.sh         # the quickstart, timed, plus a host-namespace cleanliness check
```

`scripts/lab-vm.sh up|sync|ssh|down` manages a throwaway Incus VM for the Linux parts.

## Site

`web/` holds the pages as JSX components with one shared layout, top bar and footer. `site/` is the build output and is committed, so serving needs nothing but a static file server:

```bash
cd site && python3 -m http.server 8080
```

To change the site: edit `web/`, then `pnpm install` (once) and `pnpm build`. `run-checks` fails when `site/` does not match a fresh build.

## Repository and image

- source: https://github.com/Spektral-Tech/zts
- CI: one workflow, one run per commit on `main`. `verify` runs every check and both acceptance suites; `pages` deploys `site/` when it passes; `release` builds and pushes the images only when the commit carries a `vX.Y.Z` tag equal to `VERSION`.
- image: `ghcr.io/spektral-tech/zts` (`:X.Y.Z`, `:latest`; bash essentials as `:X.Y.Z-bash`, `:bash`). Nothing is pushed from a workstation.

## License

Apache-2.0. See `LICENSE`.
