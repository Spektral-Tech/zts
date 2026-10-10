# ZTS

Status: v0.1.0 pre-release · License: Apache-2.0

ZTS gives any unmodified container only the network paths its profile declares. By name, by port, by transport. No proxy, no SDK, no CA, no ambient trust. Everything else is unreachable by construction.

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

The manifest lives in the `zts` volume (`/etc/zts/zts.yaml`). Edit it and the controller picks it up on the next container event, or `docker restart zts`.

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
- image: `ghcr.io/spektral-tech/zts`, built and pushed only by the `release` workflow when a `vX.Y.Z` tag is pushed to the public repository (`:X.Y.Z`, `:latest`; bash essentials as `:X.Y.Z-bash`, `:bash`). Nothing is pushed from a workstation.

## License

Apache-2.0. See `LICENSE`.
