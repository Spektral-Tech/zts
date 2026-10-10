#!/usr/bin/env bash
# The path the site promises: only Docker installed, under two minutes.
# Runs the same three commands shown on the site. Set ZTS_PRESET=coding-agent
# (and no TTY) for CI; ZTS_IMAGE to test a local build.
set -Eeuo pipefail
IMAGE=${ZTS_IMAGE:-ghcr.io/spektral-tech/zts}
# On failure, show what the controller saw.
trap 'rc=$?; if (( rc != 0 )); then echo "--- controller logs" >&2; docker logs zts 2>&1 | tail -20 >&2; fi' EXIT
TTY=-it; [[ -t 0 ]] || TTY=-i
start=$(date +%s)

docker rm -f zts >/dev/null 2>&1 || true

docker run --rm $TTY ${ZTS_PRESET:+-e ZTS_PRESET} -v zts:/etc/zts "$IMAGE" init
docker run -d --name zts --restart unless-stopped --privileged --pid=host --network host \
    -v /var/run/docker.sock:/var/run/docker.sock -v zts:/etc/zts "$IMAGE" up

docker rm -f agent >/dev/null 2>&1 || true
docker run -d --name agent --network none --label zts.profile=dev alpine sleep infinity
for _ in $(seq 1 40); do { docker logs zts 2>&1 || true; } | grep 'converged (1' >/dev/null && break; sleep 0.25; done
if ! docker exec agent wget -qO- https://api.github.com/zen; then
  # The zen endpoint rate-limits anonymous callers per address (shared CI
  # egress hits that). Any HTTP answer still proves the path exists.
  docker exec agent sh -c 'wget -S --spider -T6 https://api.github.com/zen 2>&1 | grep -q "HTTP/" && echo "api.github.com answered (rate-limited reply, path exists)"'
fi

echo
if docker exec agent wget -T3 -qO- https://example.com 2>/dev/null; then
  echo "agent reached an undeclared name (must not)" >&2; exit 1
fi
echo "example.com: no path (not declared)"
docker rm -f agent >/dev/null

# The substrate policy must live in its own namespace, never in the host's.
if docker run --rm --privileged --pid=host alpine nsenter -t 1 -n -- nft list tables 2>/dev/null | grep -x 'table inet zts' >/dev/null; then
  echo "host namespace carries the substrate policy table (must not)" >&2; exit 1
fi
echo "host namespace: clean"
echo "elapsed: $(( $(date +%s) - start ))s"
