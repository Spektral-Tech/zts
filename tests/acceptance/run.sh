#!/usr/bin/env bash
# Acceptance suite for the ZTS reference (SPEC §17 plus name-based reachability).
# Needs: root, Linux, docker, nft, dnsmasq, wg (test 5 is skipped without a
# loadable wireguard module). Oracles never read ZTS internals: only docker
# exec/inspect from the workload's point of view.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ZTS=${ZTS_BIN:-./zts.sh}
IMG=${ZTS_TEST_IMAGE:-alpine:3.20}
TMP=$(mktemp -d)
n=0; pass=0; fail=0; skip=0
HOST_IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
LAN_GW=$(ip -4 route show default | awk '{print $3}' | head -1)

say()  { printf '%s\n' "$*"; }
ok()   { pass=$((pass+1)); say "ok $n - $*"; }
nok()  { fail=$((fail+1)); say "not ok $n - $*"; }
skp()  { skip=$((skip+1)); say "ok $n - $* # SKIP"; }
t()    { n=$((n+1)); say "# $n: $1"; }

PEER_PID=""; HOST_PID=""; UP_PID=""
cleanup() {
  [[ -z $UP_PID ]] || kill -- -"$UP_PID" 2>/dev/null || kill "$UP_PID" 2>/dev/null || true
  [[ -z $PEER_PID ]] || kill "$PEER_PID" 2>/dev/null || true
  [[ -z $HOST_PID ]] || kill "$HOST_PID" 2>/dev/null || true
  docker ps -aq --filter name='^ztst-' | xargs -r docker rm -f >/dev/null 2>&1 || true
  "$ZTS" destroy "$TMP/m.yaml" >/dev/null 2>&1 || true
  ip netns del ztst-peer 2>/dev/null || true
  ip link del ztst-wgpeer 2>/dev/null || true
}
trap 'cleanup; rm -rf "$TMP"' EXIT

run_c() { # run_c <name> <profile> [docker args...]
  local name=$1 profile=$2; shift 2
  docker run -d --name "$name" --network none --label "zts.profile=$profile" "$@" "$IMG" sleep infinity >/dev/null
}
apply()    { "$ZTS" apply "$TMP/m.yaml" >"$TMP/apply.log" 2>&1 || { cat "$TMP/apply.log"; echo "--- ip rule"; ip -n ztst rule; echo "--- status"; "$ZTS" status "$TMP/m.yaml" 2>&1 | grep -E 'ztst-|policy'; return 1; }; }
dns_nx()   { { docker exec "$1" nslookup "$2" 2>&1 || true; } | grep "NXDOMAIN" >/dev/null; }
ip_of()    { docker exec "$1" ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }
can_tcp()  { docker exec "$1" nc -w 2 "$2" "$3" </dev/null >/dev/null 2>&1; }
can_http() { docker exec "$1" wget -T 4 -qO- "$2" >/dev/null 2>&1; }
can_dns()  { docker exec "$1" nslookup "$2" >/dev/null 2>&1; }
start_listener() { docker exec -d "$1" sh -c "while :; do nc -l -p $2 -e /bin/true; done"; }

manifest_base() {
  cat >"$TMP/m.yaml" <<YAML
version: 1
substrate: { namespace: ztst, pool: 100.64.0.0/10 }
transports:
  host: { type: host }
resources:
  db: { workload: ztst-db }
  github: { names: [github.com, "*.github.com"] }
  anyname: { names: ["*"] }
  everything: { cidrs: [0.0.0.0/0] }
  lan: { cidrs: [$HOST_IP/32] }
profiles:
  isolated: { allow: [] }
  dev:
    allow:
      - { to: db, protocol: tcp, ports: [5432] }
      - { to: github, via: host, protocol: tcp, ports: [443] }
  webdev:
    allow:
      - { to: anyname, via: host, protocol: tcp, ports: [80, 443] }
  cidrall:
    allow:
      - { to: everything, via: host, protocol: tcp, ports: [80, 443] }
  lanok:
    allow:
      - { to: lan, via: host, protocol: tcp, ports: [2222] }
YAML
}

cleanup
manifest_base

# ---------------------------------------------------------------- 1
t "an arbitrary --network none container gains a ZTS interface, image unmodified"
run_c ztst-db isolated; run_c ztst-dev dev
if apply && [[ -n $(ip_of ztst-dev) ]] && docker exec ztst-dev ip link show eth0 >/dev/null; then ok "eth0 present with $(ip_of ztst-dev)"; else nok "no eth0"; fi

# ---------------------------------------------------------------- 2
t "Docker stays unmodified: NetworkMode is still none"
if [[ $(docker inspect -f '{{.HostConfig.NetworkMode}}' ztst-dev) == none ]]; then ok "NetworkMode=none"; else nok "NetworkMode changed"; fi

# ---------------------------------------------------------------- 3
t "empty profile reaches nothing: gateway, host, LAN, other workload, internet"
run_c ztst-iso isolated; apply
gw=$(docker exec ztst-iso ip -4 route show default | awk '{print $3}')
if ! can_tcp ztst-iso "$gw" 53 && ! can_tcp ztst-iso "$HOST_IP" 22 && ! can_tcp ztst-iso "$LAN_GW" 53 \
   && ! can_tcp ztst-iso "$(ip_of ztst-db)" 5432 && ! can_http ztst-iso https://1.1.1.1 && ! can_dns ztst-iso github.com; then
  ok "no path anywhere"; else nok "isolated reached something"; fi

# ---------------------------------------------------------------- 4
t "same-host relation enables only the declared protocol/port, one direction"
start_listener ztst-db 5432; start_listener ztst-db 5433; start_listener ztst-dev 5432; sleep 0.5
db=$(ip_of ztst-db); dev=$(ip_of ztst-dev)
if can_tcp ztst-dev "$db" 5432 && ! can_tcp ztst-dev "$db" 5433 && ! can_tcp ztst-db "$dev" 5432; then
  ok "5432 open, 5433 closed, reverse closed"; else nok "relation leaked or missing"; fi

# ---------------------------------------------------------------- 5
t "transport-bound relation exits only through the declared WireGuard transport"
if ! modprobe wireguard 2>/dev/null || ! command -v wg >/dev/null; then
  skp "wireguard module or wg tool unavailable"
else
  umask 077
  wg genkey >"$TMP/zts.key"; wg genkey >"$TMP/peer.key"
  ZPUB=$(wg pubkey <"$TMP/zts.key"); PPUB=$(wg pubkey <"$TMP/peer.key")
  ip netns add ztst-peer
  ip link add ztst-wgpeer type wireguard
  ip link set ztst-wgpeer netns ztst-peer
  ip -n ztst-peer addr add 10.255.255.1/32 dev ztst-wgpeer
  ip netns exec ztst-peer wg set ztst-wgpeer listen-port 51999 private-key "$TMP/peer.key" \
    peer "$ZPUB" allowed-ips 10.255.255.2/32,100.64.0.0/10
  ip -n ztst-peer link set ztst-wgpeer up
  ip -n ztst-peer link set lo up
  ip -n ztst-peer route add 10.255.255.2/32 dev ztst-wgpeer
  ip -n ztst-peer route add 100.64.0.0/10 dev ztst-wgpeer
  ip netns exec ztst-peer python3 -c 'import socket;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("10.255.255.1",8080));s.listen(8)
while True:
    c,_=s.accept();c.close()' &
  PEER_PID=$!
  sleep 0.5
  cat >>"$TMP/m.yaml" <<YAML
  egress:
    allow:
      - { to: peer, via: wg, protocol: tcp, ports: [8080] }
YAML
  python3 - "$TMP/m.yaml" "$TMP/zts.key" "$PPUB" <<'PY'
import sys
p,key,pub=sys.argv[1:]
s=open(p).read()
s=s.replace("transports:\n  host: { type: host }\n",
 "transports:\n  host: { type: host }\n  wg:\n    type: wireguard\n    address: 10.255.255.2/32\n    private_key_file: %s\n    peer: { public_key: %s, endpoint: 127.0.0.1:51999, allowed_ips: [0.0.0.0/0] }\n" % (key,pub))
s=s.replace("resources:\n","resources:\n  peer: { cidrs: [10.255.255.1/32] }\n")
open(p,'w').write(s)
PY
  run_c ztst-egress egress; apply
  if can_tcp ztst-egress 10.255.255.1 8080 && ! can_tcp ztst-dev 10.255.255.1 8080 && ! can_tcp ztst-iso 10.255.255.1 8080; then
    ok "reachable only via wg, only for the egress profile"; else nok "wg path wrong"; fi
fi

# ---------------------------------------------------------------- 6
t "removing ZTS state returns workloads to no connectivity"
"$ZTS" destroy "$TMP/m.yaml" >/dev/null 2>&1
if ! docker exec ztst-dev ip link show eth0 >/dev/null 2>&1 && ! can_tcp ztst-dev "$db" 5432; then
  ok "eth0 gone, nothing reachable"; else nok "state survived destroy"; fi

# ---------------------------------------------------------------- 7
t "re-running reconciliation on converged state reports no changes"
apply; apply
if { "$ZTS" plan "$TMP/m.yaml" 2>/dev/null || true; } | grep '^No changes\.$' >/dev/null; then ok "plan: No changes."; else nok "plan still wants changes: $("$ZTS" plan "$TMP/m.yaml" 2>&1 | tail -3)"; fi

# ---------------------------------------------------------------- 8
t "a restarted container is drift and gets reattached"
docker restart ztst-dev >/dev/null; sleep 0.5
drift=$({ "$ZTS" status "$TMP/m.yaml" 2>/dev/null || true; } | grep -c 'ztst-dev.*state=drift' || true)
apply; start_listener ztst-db 5432; sleep 0.3
if (( drift == 1 )) && can_tcp ztst-dev "$(ip_of ztst-db)" 5432; then ok "drift detected, reattached, relation back"; else nok "drift=$drift"; fi

# ---------------------------------------------------------------- 9
t "a workload cannot gain reachability by spoofing another workload's address"
run_c ztst-spoof isolated --cap-add NET_ADMIN; apply
dev=$(ip_of ztst-dev); db=$(ip_of ztst-db)
docker exec ztst-spoof ip addr add "$dev/32" dev eth0
if ! docker exec ztst-spoof nc -w 2 -s "$dev" "$db" 5432 </dev/null >/dev/null 2>&1; then ok "spoofed source dropped"; else nok "spoof reached db"; fi

# ---------------------------------------------------------------- 10
t "no ZTS process remains inside a workload"
procs=$(docker top ztst-dev -o pid | tail -n +2 | wc -l)
if (( procs == 1 )); then ok "only the workload's own process"; else nok "$procs processes"; fi

# ---------------------------------------------------------------- 11
t "names: a declared name resolves and is reachable over end-to-end TLS, no proxy, no CA"
if can_dns ztst-dev api.github.com && can_http ztst-dev https://api.github.com/zen; then ok "api.github.com 200 over TLS"; else nok "github unreachable (internet on this host?)"; fi

# ---------------------------------------------------------------- 12
t "names: an undeclared name does not resolve and no packet leaves"
if dns_nx ztst-dev example.com && ! can_http ztst-dev https://example.com; then ok "example.com: NXDOMAIN, no path"; else nok "undeclared name leaked or resolver unreachable: $(docker exec ztst-dev nslookup example.com 2>&1 | tail -2 | tr '\n' ' ')"; fi

# ---------------------------------------------------------------- 13
t "names: a raw address that was never resolved for a declared name is dropped"
if ! can_http ztst-dev https://1.1.1.1; then ok "1.1.1.1 dropped for the github-only profile"; else nok "raw IP leaked"; fi

# ---------------------------------------------------------------- 14
t "host transport: any-name profile reaches the internet but never host, LAN or link-local"
run_c ztst-web webdev; apply
if can_tcp ztst-web 1.1.1.1 443 && can_dns ztst-web example.com && ! can_tcp ztst-web "$HOST_IP" 22 && ! can_tcp ztst-web "$LAN_GW" 53 && ! can_tcp ztst-web 169.254.100.1 22; then
  ok "internet yes, private no"; else nok "private guard failed"; fi

# ---------------------------------------------------------------- 15
t "host transport: 0.0.0.0/0 as a CIDR still excludes private space; an explicit private CIDR is honored"
# a listener on the host's own LAN address, so "reachable" means something
python3 -c 'import socket,sys;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind((sys.argv[1],2222));s.listen(8)
while True:
    c,_=s.accept();c.close()' "$HOST_IP" &
HOST_PID=$!; sleep 0.5
run_c ztst-all cidrall; run_c ztst-lan lanok; apply
r=""
can_tcp ztst-all 1.1.1.1 443           && r="$r all->internet:yes" || r="$r all->internet:NO"
can_tcp ztst-all "$HOST_IP" 2222       && r="$r all->host:LEAK"    || r="$r all->host:no"
can_tcp ztst-lan "$HOST_IP" 2222       && r="$r lan->host:yes"     || r="$r lan->host:NO"
can_tcp ztst-lan "$HOST_IP" 80         && r="$r lan->host80:LEAK"  || r="$r lan->host80:no"
can_tcp ztst-web "$HOST_IP" 2222       && r="$r web->host:LEAK"    || r="$r web->host:no"
if [[ $r != *NO* && $r != *LEAK* ]]; then ok "guard holds for /0, explicit private CIDR passes"; else nok "cidr guard wrong:$r"; fi

# ---------------------------------------------------------------- 16
t "show/load: an invalid manifest is never saved, a valid one round-trips"
cp "$TMP/m.yaml" "$TMP/orig.yaml"
if ! printf 'version: 1\nprofiles:\n  x:\n    allow:\n      - { to: nope }\n' | "$ZTS" load "$TMP/m.yaml" >/dev/null 2>&1 \
   && cmp -s "$TMP/m.yaml" "$TMP/orig.yaml" && "$ZTS" load "$TMP/m.yaml" < "$TMP/orig.yaml" >/dev/null 2>&1 \
   && "$ZTS" show "$TMP/m.yaml" | cmp -s - "$TMP/orig.yaml"; then
  ok "invalid rejected, original kept, show == load"; else nok "show/load wrong"; fi

# ---------------------------------------------------------------- 17
t "up applies a changed manifest without a restart"
docker ps -aq --filter name='^ztst-' | xargs -r docker rm -f >/dev/null 2>&1
"$ZTS" destroy "$TMP/m.yaml" >/dev/null 2>&1
cat >"$TMP/m.yaml" <<YAML
version: 1
substrate: { namespace: ztst, pool: 100.64.0.0/10 }
resources:
  db: { workload: ztst-db }
profiles:
  db: { allow: [] }
  app: { allow: [] }
YAML
run_c ztst-db db; run_c ztst-app app
# own session, so the whole controller (event stream included) can be killed
setsid "$ZTS" up "$TMP/m.yaml" >"$TMP/up.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 40); do grep -q 'converged (2' "$TMP/up.log" && break; sleep 0.25; done
start_listener ztst-db 5432; sleep 0.3
before=0; can_tcp ztst-app "$(ip_of ztst-db)" 5432 && before=1
cat >"$TMP/new.yaml" <<YAML
version: 1
substrate: { namespace: ztst, pool: 100.64.0.0/10 }
resources:
  db: { workload: ztst-db }
profiles:
  db: { allow: [] }
  app:
    allow:
      - { to: db, protocol: tcp, ports: [5432] }
YAML
"$ZTS" load "$TMP/m.yaml" < "$TMP/new.yaml" >/dev/null 2>&1
after=0
for _ in $(seq 1 30); do can_tcp ztst-app "$(ip_of ztst-db)" 5432 && after=1 && break; sleep 0.3; done
kill -- -"$UP_PID" 2>/dev/null || kill "$UP_PID" 2>/dev/null; wait "$UP_PID" 2>/dev/null || true
if (( before == 0 && after == 1 )); then ok "relation appeared after load, no restart"; else nok "before=$before after=$after: $(tail -3 "$TMP/up.log" | tr '\n' ' ')"; fi

say "1..$n"
say "# pass=$pass fail=$fail skip=$skip"
(( fail == 0 ))
