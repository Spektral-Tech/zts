#!/usr/bin/env bash
# zts.sh - ZTS bash essentials: a declarative Linux-network reconciler in one file.
#
# "Do the most with the least." This is the readable reference implementation.
# It materializes, per container, only the network paths a manifest declares.
#
# Contract:
#   - Docker is read-only inventory (Engine API over the Unix socket; no CLI needed).
#   - Managed containers MUST be created with --network none and the label zts.profile.
#   - zts never starts/stops/restarts/connects a container.
#   - Materialized state lives in Linux netns/veth/routes/nftables/WireGuard/dnsmasq.
#   - Nothing sits in the packet path after apply. `up` only reacts to runtime events.
#
# Labels:
#   zts.profile=<manifest profile>          required
#   zts.identity=<stable logical identity>  optional, defaults to the container name
#
# Commands:
#   zts.sh init     [manifest]   write a manifest from a preset (asks once on a TTY)
#   zts.sh check    [manifest]   validate a manifest without root
#   zts.sh edit     [manifest]   open it in $EDITOR; only a valid result is saved
#   zts.sh show     [manifest]   print it
#   zts.sh load     [manifest]   replace it from stdin, after validation
#   zts.sh plan     [manifest]
#   zts.sh apply    [manifest]
#   zts.sh status   [manifest]
#   zts.sh up       [manifest]   apply, then reconcile on container start/die and manifest change
#   zts.sh destroy  [manifest]
#   zts.sh selftest
#
# Dependencies: bash >= 4, curl, jq, yq (Mike Farah v4), ip, nsenter, nft, flock, cksum.
# Optional: dnsmasq (resources with `names`), wg (transports of type wireguard),
#           iptables (only to open Docker's DOCKER-USER chain for the host transport).

if (( BASH_VERSINFO[0] < 4 )); then
  printf '[zts] error: requires bash >= 4 (found %s)\n' "$BASH_VERSION" >&2
  exit 1
fi

set -Eeuo pipefail

PROGRAM=${0##*/}
COMMAND=${1:-}
# Default manifest: /etc/zts/zts.yaml when that directory exists (the image
# mounts its volume there), else zts.yaml in the current directory.
if [[ -n ${2:-} ]]; then
  MANIFEST=$2
elif [[ -d /etc/zts ]]; then
  MANIFEST=/etc/zts/zts.yaml
else
  MANIFEST=zts.yaml
fi

readonly RULE_PREF=10000
readonly TABLE_MIN=1000
readonly TABLE_SPAN=20000
readonly HOSTLINK_HOST_IF=zts-host
readonly HOSTLINK_NS_IF=host0
readonly HOSTLINK_HOST_IP=169.254.100.1
readonly HOSTLINK_NS_IP=169.254.100.2
readonly RUN_DIR=/run/zts

DOCKER_SOCK=${ZTS_DOCKER_SOCK:-/var/run/docker.sock}
# When zts runs inside a container with --pid=host, host paths (like a
# container's resolv.conf) are reachable under /proc/1/root.
HOST_ROOT=${ZTS_HOST_ROOT:-}

# In-container mode: run a command in the host's mount namespace (PID 1 is the
# host's init because of --pid=host). Used only to create/delete the named
# network namespace there, so it outlives this container.
host_exec() {
  nsenter -t 1 -m -u -i -- "$@"
}

setup_host_mode() {
  [[ -n $HOST_ROOT ]] || return 0
  [[ -d $HOST_ROOT/proc ]] || die "ZTS_HOST_ROOT=$HOST_ROOT is not a host root (run with --privileged --pid=host)"
  mkdir -p "$HOST_ROOT/run/netns"
  if [[ ! -L /run/netns ]]; then
    rm -rf /run/netns
    ln -s "$HOST_ROOT/run/netns" /run/netns
  fi
}

ns_add() {
  if [[ -n $HOST_ROOT ]]; then
    # New netns held alive by a bind mount made in the host's mount namespace.
    unshare -n -- nsenter -t 1 -m -u -i -- sh -c \
      "touch /run/netns/$ZNS && mount --bind /proc/self/ns/net /run/netns/$ZNS" \
      || die "failed to create namespace '$ZNS' in the host mount namespace"
  else
    ip netns add "$ZNS"
  fi
}

ns_del() {
  if [[ -n $HOST_ROOT ]]; then
    host_exec sh -c "umount /run/netns/$ZNS 2>/dev/null; rm -f /run/netns/$ZNS"
  else
    ip netns del "$ZNS"
  fi
}

log()  { printf '%s\n' "$*" >&2; }
info() { printf '[zts] %s\n' "$*" >&2; }
warn() { printf '[zts] warning: %s\n' "$*" >&2; }
die()  { printf '[zts] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage:
  $PROGRAM init     [manifest.yaml]   write a manifest from a preset
  $PROGRAM check    [manifest.yaml]   validate a manifest (no root needed)
  $PROGRAM edit     [manifest.yaml]   edit in \$EDITOR; only a valid result is saved
  $PROGRAM show     [manifest.yaml]   print the manifest
  $PROGRAM load     [manifest.yaml]   replace the manifest from stdin, after validation
  $PROGRAM plan     [manifest.yaml]
  $PROGRAM apply    [manifest.yaml]
  $PROGRAM status   [manifest.yaml]
  $PROGRAM up       [manifest.yaml]   apply and keep reconciling on container events
  $PROGRAM destroy  [manifest.yaml]
  $PROGRAM selftest
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root"
}

require_runtime_deps() {
  local cmd
  for cmd in curl jq ip nsenter nft yq cksum awk sed grep sort flock; do
    need_cmd "$cmd"
  done
  yq --version 2>/dev/null | grep -E 'version v?4\.' >/dev/null || die "requires Mike Farah yq v4"
  [[ -S $DOCKER_SOCK ]] || die "docker socket not found: $DOCKER_SOCK"
}

# ---------- IPv4 helpers ----------

ipv4_to_int() {
  local ip=$1 a b c d
  IFS=. read -r a b c d <<<"$ip"
  printf '%u\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

int_to_ipv4() {
  local n=$1
  printf '%d.%d.%d.%d\n' \
    "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" "$(( (n >> 8) & 255 ))" "$(( n & 255 ))"
}

validate_ipv4() {
  local ip=$1 a b c d oct
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  for oct in "$a" "$b" "$c" "$d"; do
    (( 10#$oct >= 0 && 10#$oct <= 255 )) || return 1
  done
}

validate_cidr() {
  local cidr=$1 ip prefix
  [[ $cidr == */* ]] || return 1
  ip=${cidr%/*}
  prefix=${cidr#*/}
  validate_ipv4 "$ip" || return 1
  [[ $prefix =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 ))
}

# A DNS name as accepted in resources.<name>.names: "*" (any), "*.example.com"
# (the domain and its subdomains) or "example.com" (idem: dnsmasq matches the
# domain and everything below it).
validate_name() {
  local n=$1
  [[ $n == '*' ]] && return 0
  n=${n#\*.}
  [[ $n =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

cidr_network_int() {
  local cidr=$1 ip prefix n mask
  ip=${cidr%/*}
  prefix=${cidr#*/}
  n=$(ipv4_to_int "$ip")
  if (( prefix == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  printf '%u\n' "$(( n & mask ))"
}

readonly PRIVATE_RANGES="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"

# True when the CIDR lies entirely inside one of the guarded ranges, i.e. the
# manifest named private space on purpose.
cidr_is_private() {
  local cidr=$1 range rprefix cprefix
  cprefix=${cidr#*/}
  for range in $PRIVATE_RANGES; do
    rprefix=${range#*/}
    (( cprefix >= rprefix )) || continue
    [[ $(cidr_network_int "${cidr%/*}/$rprefix") == $(cidr_network_int "$range") ]] && return 0
  done
  return 1
}

hash_u32() {
  printf '%s' "$1" | cksum | awk '{print $1}'
}

hash_hex8() {
  printf '%08x\n' "$(hash_u32 "$1")"
}

# Stable /30 carved from substrate.pool based on workload identity.
endpoint_for_identity() {
  local identity=$1 pool=$2
  local prefix base slots hash slot net
  prefix=${pool#*/}
  (( prefix <= 30 )) || die "substrate.pool must be /30 or larger"
  base=$(cidr_network_int "$pool")
  slots=$(( 1 << (30 - prefix) ))
  hash=$(hash_u32 "$identity")
  slot=$(( hash % slots ))
  net=$(( base + slot * 4 ))
  printf '%s %s %s\n' "$(int_to_ipv4 "$((net + 1))")" "$(int_to_ipv4 "$((net + 2))")" "$slot"
}

endpoint_ifname()  { printf 'zt%s\n' "$(hash_hex8 "endpoint:$1")"; }
transport_ifname() { printf 'wg%s\n' "$(hash_hex8 "transport:$1")"; }
resource_setname() { printf 'r_%s\n' "$(hash_hex8 "resource:$1")"; }

profile_table() {
  local h
  h=$(hash_u32 "profile:$1")
  printf '%d\n' "$(( TABLE_MIN + (h % TABLE_SPAN) ))"
}

# ---------- manifest helpers ----------

mget() { yq -r "$1" "$MANIFEST"; }

manifest_has_profile() {
  PROFILE=$1 yq -e '.profiles[strenv(PROFILE)] != null' "$MANIFEST" >/dev/null 2>&1
}
profile_allow_count() {
  PROFILE=$1 yq -r '.profiles[strenv(PROFILE)].allow // [] | length' "$MANIFEST"
}
allow_field() {
  PROFILE=$1 INDEX=$2 FIELD=$3 \
    yq -r '.profiles[strenv(PROFILE)].allow[(strenv(INDEX) | tonumber)][strenv(FIELD)] // ""' "$MANIFEST"
}
allow_ports() {
  PROFILE=$1 INDEX=$2 \
    yq -r '.profiles[strenv(PROFILE)].allow[(strenv(INDEX) | tonumber)].ports // [] | .[]' "$MANIFEST"
}
resource_exists() {
  RESOURCE=$1 yq -e '.resources[strenv(RESOURCE)] != null' "$MANIFEST" >/dev/null 2>&1
}
resource_workload() {
  RESOURCE=$1 yq -r '.resources[strenv(RESOURCE)].workload // ""' "$MANIFEST"
}
resource_cidrs() {
  RESOURCE=$1 yq -r '.resources[strenv(RESOURCE)].cidrs // [] | .[]' "$MANIFEST"
}
resource_names() {
  RESOURCE=$1 yq -r '.resources[strenv(RESOURCE)].names // [] | .[]' "$MANIFEST"
}
transport_exists() {
  TRANSPORT=$1 yq -e '.transports[strenv(TRANSPORT)] != null' "$MANIFEST" >/dev/null 2>&1
}
transport_field() {
  TRANSPORT=$1 yq -r ".transports[strenv(TRANSPORT)]${2}" "$MANIFEST"
}
transport_type() {
  transport_field "$1" '.type // "wireguard"'
}
transport_allowed_ips() {
  TRANSPORT=$1 yq -r '.transports[strenv(TRANSPORT)].peer.allowed_ips // [] | .[]' "$MANIFEST"
}
transport_list() {
  mget '.transports // {} | keys | .[]'
}

# ---------- Docker Engine API (read-only) ----------

dapi() {
  # dapi <path> [curl args...]
  local path=$1; shift
  curl -sS --fail --unix-socket "$DOCKER_SOCK" "http://docker/$path" "$@"
}

docker_running_managed_ids() {
  dapi containers/json -G --data-urlencode 'filters={"label":["zts.profile"],"status":["running"]}' \
    | jq -r '.[].Id' | sort
}

# ---------- discovered desired inventory ----------

declare -a IDENTITIES=()
declare -A CID_BY_ID=()
declare -A PID_BY_ID=()
declare -A PROFILE_BY_ID=()
declare -A HOST_IP_BY_ID=()
declare -A WORKLOAD_IP_BY_ID=()
declare -A ZIF_BY_ID=()
declare -A RESOLV_BY_ID=()
declare -A ID_BY_SLOT=()
declare -A TABLE_BY_PROFILE=()
declare -A PROFILE_BY_TABLE=()
declare -a PROFILES=()
declare -A NAME_TRANSPORT_BY_PROFILE=()

ZNS=""
POOL=""
RESOLVERS=""
HAS_HOST_TRANSPORT=0
HOST_ALLOW_PRIVATE=false

validate_manifest() {
  [[ -f $MANIFEST ]] || die "manifest not found: $MANIFEST (run '$PROGRAM init' first, or set ZTS_PRESET)"

  local version
  version=$(mget '.version // 0')
  [[ $version == 1 ]] || die "manifest version must be 1"

  ZNS=$(mget '.substrate.namespace // "zts"')
  [[ $ZNS =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || die "invalid substrate.namespace: $ZNS"

  POOL=$(mget '.substrate.pool // "100.64.0.0/10"')
  validate_cidr "$POOL" || die "invalid substrate.pool: $POOL"
  local prefix=${POOL#*/}
  (( prefix <= 30 )) || die "substrate.pool must be /30 or larger"

  RESOLVERS=$(mget '.substrate.resolvers // ["1.1.1.1","9.9.9.9"] | .[]' | paste -sd' ' -)
  local r
  for r in $RESOLVERS; do
    validate_ipv4 "$r" || die "invalid substrate.resolvers entry: $r"
  done

  local t kind addr keyfile pub endpoint keepalive allowed
  while IFS= read -r t; do
    [[ -n $t ]] || continue
    [[ $t =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || die "invalid transport name: $t"
    kind=$(transport_type "$t")
    case "$kind" in
      host)
        (( HAS_HOST_TRANSPORT == 0 )) || die "only one transport of type=host is supported"
        HAS_HOST_TRANSPORT=1
        HOST_ALLOW_PRIVATE=$(transport_field "$t" '.allow_private // false')
        [[ $HOST_ALLOW_PRIVATE == true || $HOST_ALLOW_PRIVATE == false ]] || die "transport '$t': allow_private must be true/false"
        ;;
      wireguard)
        addr=$(transport_field "$t" '.address // ""')
        validate_cidr "$addr" || die "transport '$t': invalid address '$addr'"
        keyfile=$(transport_field "$t" '.private_key_file // ""')
        [[ -n $keyfile ]] || die "transport '$t': private_key_file is required"
        pub=$(transport_field "$t" '.peer.public_key // ""')
        [[ -n $pub ]] || die "transport '$t': peer.public_key is required"
        endpoint=$(transport_field "$t" '.peer.endpoint // ""')
        [[ -n $endpoint ]] || die "transport '$t': peer.endpoint is required"
        keepalive=$(transport_field "$t" '.peer.persistent_keepalive // 0')
        [[ $keepalive =~ ^[0-9]+$ ]] || die "transport '$t': invalid persistent_keepalive"
        (( keepalive >= 0 && keepalive <= 65535 )) || die "transport '$t': persistent_keepalive out of range"
        local have_allowed=0
        while IFS= read -r allowed; do
          [[ -n $allowed ]] || continue
          have_allowed=1
          validate_cidr "$allowed" || die "transport '$t': invalid allowed_ip '$allowed'"
        done < <(transport_allowed_ips "$t")
        (( have_allowed == 1 )) || die "transport '$t': peer.allowed_ips cannot be empty"
        ;;
      *) die "transport '$t': unsupported type '$kind' (host, wireguard)" ;;
    esac
  done < <(transport_list)

  # Unknown top-level keys are rejected (SPEC §13).
  local key
  while IFS= read -r key; do
    case "$key" in version|substrate|transports|resources|profiles) ;; *) die "unknown top-level key: $key" ;; esac
  done < <(mget 'keys | .[]')
}

discover_workloads() {
  local cid identity profile pid mode privileged name resolv host_ip workload_ip slot zif extra_if
  local -A seen_identity=()

  while IFS= read -r cid; do
    [[ -n $cid ]] || continue
    local j
    j=$(dapi "containers/$cid/json")
    pid=$(jq -r '.State.Pid' <<<"$j")
    name=$(jq -r '.Name | ltrimstr("/")' <<<"$j")
    profile=$(jq -r '.Config.Labels["zts.profile"] // ""' <<<"$j")
    identity=$(jq -r '.Config.Labels["zts.identity"] // ""' <<<"$j")
    mode=$(jq -r '.HostConfig.NetworkMode' <<<"$j")
    privileged=$(jq -r '.HostConfig.Privileged' <<<"$j")
    resolv=$(jq -r '.ResolvConfPath // ""' <<<"$j")
    [[ -n $identity ]] || identity=$name

    [[ -n $profile ]] || die "$name: missing zts.profile label"
    [[ $identity =~ ^[a-zA-Z0-9][a-zA-Z0-9_./-]{0,63}$ ]] || die "$name: invalid identity '$identity'"
    [[ $mode == none ]] || die "$identity: Docker NetworkMode must be 'none' (got '$mode')"
    [[ $privileged == false ]] || die "$identity: privileged containers are not accepted"
    manifest_has_profile "$profile" || die "$identity: unknown profile '$profile'"
    [[ -z ${seen_identity[$identity]:-} ]] || die "duplicate running identity '$identity'"
    seen_identity[$identity]=1
    (( pid > 0 )) || die "$identity: container has no PID"

    read -r host_ip workload_ip slot < <(endpoint_for_identity "$identity" "$POOL")
    zif=$(endpoint_ifname "$identity")

    if [[ -n ${ID_BY_SLOT[$slot]:-} && ${ID_BY_SLOT[$slot]} != "$identity" ]]; then
      die "address allocation collision: '$identity' and '${ID_BY_SLOT[$slot]}' map to slot $slot"
    fi
    ID_BY_SLOT[$slot]=$identity

    # With --network none, only lo is expected before ZTS; eth0 is accepted as
    # already materialized ZTS state. Kernels with built-in tunnel drivers also
    # drop fallback devices (tunl0, erspan0, sit0...) into every new netns;
    # those carry no path. Anything else is unexpected.
    while IFS= read -r extra_if; do
      [[ -n $extra_if ]] || continue
      [[ $extra_if =~ ^(lo|eth0|tunl0|gre0|gretap0|erspan0|ip6tnl0|ip6gre0|ip6gretap0|ip6erspan0|sit0|ip_vti0|ip6_vti0|dummy0|teql0|ifb[0-9]+|bond0|nlmon0)$ ]] \
        || die "$identity: unexpected interface '$extra_if' exists inside container netns"
    done < <(nsenter -t "$pid" -n ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | sort -u)

    IDENTITIES+=("$identity")
    CID_BY_ID[$identity]=$cid
    PID_BY_ID[$identity]=$pid
    PROFILE_BY_ID[$identity]=$profile
    HOST_IP_BY_ID[$identity]=$host_ip
    WORKLOAD_IP_BY_ID[$identity]=$workload_ip
    ZIF_BY_ID[$identity]=$zif
    RESOLV_BY_ID[$identity]=$resolv

    local table
    table=$(profile_table "$profile")
    if [[ -n ${PROFILE_BY_TABLE[$table]:-} && ${PROFILE_BY_TABLE[$table]} != "$profile" ]]; then
      die "routing-table hash collision: profiles '$profile' and '${PROFILE_BY_TABLE[$table]}'"
    fi
    if [[ -z ${TABLE_BY_PROFILE[$profile]:-} ]]; then
      PROFILES+=("$profile")
    fi
    PROFILE_BY_TABLE[$table]=$profile
    TABLE_BY_PROFILE[$profile]=$table
  done < <(docker_running_managed_ids)
}

validate_profile_graph() {
  # validate_profile_graph <profile> <check_running_workloads 0|1>
  local profile=$1 strict=$2 count i resource target via protocol port cidr name
  count=$(profile_allow_count "$profile")

  for ((i=0; i<count; i++)); do
    resource=$(allow_field "$profile" "$i" to)
    [[ -n $resource ]] || die "profile '$profile': allow[$i].to is required"
    resource_exists "$resource" || die "profile '$profile': unknown resource '$resource'"

    protocol=$(allow_field "$profile" "$i" protocol)
    [[ -n $protocol ]] || protocol=any
    case "$protocol" in any|tcp|udp) ;; *) die "profile '$profile': allow[$i] invalid protocol '$protocol'" ;; esac

    while IFS= read -r port; do
      [[ -n $port ]] || continue
      [[ $protocol == tcp || $protocol == udp ]] || die "profile '$profile': ports require protocol tcp or udp"
      [[ $port =~ ^[0-9]+$ ]] || die "profile '$profile': invalid port '$port'"
      (( port >= 1 && port <= 65535 )) || die "profile '$profile': port '$port' out of range"
    done < <(allow_ports "$profile" "$i")

    target=$(resource_workload "$resource")
    via=$(allow_field "$profile" "$i" via)

    if [[ -n $target ]]; then
      if (( strict )); then
        [[ -n ${CID_BY_ID[$target]:-} ]] || die "resource '$resource': workload '$target' is not running/managed"
      fi
      [[ -z $via ]] || die "profile '$profile': workload resource '$resource' cannot use via='$via'"
      continue
    fi

    local have_cidr=0 have_name=0
    while IFS= read -r cidr; do
      [[ -n $cidr ]] || continue
      have_cidr=1
      validate_cidr "$cidr" || die "resource '$resource': invalid cidr '$cidr'"
    done < <(resource_cidrs "$resource")
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      have_name=1
      validate_name "$name" || die "resource '$resource': invalid name '$name'"
    done < <(resource_names "$resource")
    (( have_cidr == 1 || have_name == 1 )) || die "resource '$resource': define workload, cidrs or names"
    [[ -n $via ]] || die "profile '$profile': resource '$resource' requires via=<transport>"
    transport_exists "$via" || die "profile '$profile': unknown transport '$via'"

    if (( have_name == 1 )); then
      (( strict == 0 )) || command -v dnsmasq >/dev/null 2>&1 || die "resource '$resource' uses names: dnsmasq is required"
      if [[ -n ${NAME_TRANSPORT_BY_PROFILE[$profile]:-} && ${NAME_TRANSPORT_BY_PROFILE[$profile]} != "$via" ]]; then
        die "profile '$profile': name-based resources must all use the same transport (got '${NAME_TRANSPORT_BY_PROFILE[$profile]}' and '$via')"
      fi
      NAME_TRANSPORT_BY_PROFILE[$profile]=$via
    fi
  done
}

validate_desired_graph() {
  local identity profile t
  local -A checked=()
  for identity in "${IDENTITIES[@]}"; do
    profile=${PROFILE_BY_ID[$identity]}
    [[ -z ${checked[$profile]:-} ]] || continue
    checked[$profile]=1
    validate_profile_graph "$profile" 1
  done
  while IFS= read -r t; do
    [[ -n $t ]] || continue
    [[ $(transport_type "$t") != wireguard ]] || need_cmd wg
  done < <(transport_list)
}

# Validate a candidate file (no root, no Docker) without touching globals.
check_file() {
  ( MANIFEST=$1; check_manifest >/dev/null )
}

# edit / show / load: the manifest lives in a volume, so these are the
# documented ways to change it without knowing where the volume is.
run_show() {
  [[ -f $MANIFEST ]] || die "manifest not found: $MANIFEST"
  cat "$MANIFEST"
}

run_load() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if ! out=$(check_file "$tmp" 2>&1); then
    rm -f "$tmp"
    die "not saved: $out"
  fi
  mkdir -p "$(dirname "$MANIFEST")"
  mv -f "$tmp" "$MANIFEST"
  info "saved $MANIFEST"
}

run_edit() {
  local tmp editor answer out
  [[ -t 0 && -t 1 ]] || die "edit needs a terminal (docker run -it); use 'show' and 'load' otherwise"
  editor=${EDITOR:-${VISUAL:-vi}}
  tmp=$(mktemp --suffix=.yaml 2>/dev/null || mktemp)
  if [[ -f $MANIFEST ]]; then cat "$MANIFEST" > "$tmp"; else preset_manifest coding-agent > "$tmp"; fi
  while :; do
    $editor "$tmp"
    if out=$(check_file "$tmp" 2>&1); then
      if [[ -f $MANIFEST ]] && cmp -s "$tmp" "$MANIFEST"; then
        rm -f "$tmp"; info "no changes"; return 0
      fi
      mkdir -p "$(dirname "$MANIFEST")"
      mv -f "$tmp" "$MANIFEST"
      info "saved $MANIFEST"
      return 0
    fi
    printf '\n%s\n\n' "$out" >&2
    printf 'The manifest is invalid and was not saved. [r]eopen or [d]iscard? [r] ' >&2
    read -r answer
    case "${answer:-r}" in
      d|D) rm -f "$tmp"; info "discarded"; return 1 ;;
    esac
  done
}

# `check`: validate a manifest with no root, no Docker and no kernel access.
check_manifest() {
  local profile key
  validate_manifest
  while IFS= read -r profile; do
    [[ -n $profile ]] || continue
    [[ $profile =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || die "invalid profile name: $profile"
    while IFS= read -r key; do
      [[ $key == allow ]] || die "profile '$profile': unknown key '$key'"
    done < <(PROFILE=$profile yq -r '.profiles[strenv(PROFILE)] // {} | keys | .[]' "$MANIFEST")
    validate_profile_graph "$profile" 0
  done < <(mget '.profiles // {} | keys | .[]')
  [[ -n $(mget '.profiles // {} | keys | .[0] // ""') ]] || die "manifest declares no profiles"
  printf 'manifest ok: %s\n' "$MANIFEST"
}

# ---------- observation ----------

ns_exists() { ip netns list | awk '{print $1}' | grep -Fx "$ZNS" >/dev/null; }

zif_exists() { ns_exists && ip -n "$ZNS" link show "$1" >/dev/null 2>&1; }

wg_exists() { ns_exists && ip -n "$ZNS" link show "$1" >/dev/null 2>&1; }

hostlink_exists() {
  ip link show "$HOSTLINK_HOST_IF" >/dev/null 2>&1 && ns_exists && \
    ip -n "$ZNS" link show "$HOSTLINK_NS_IF" >/dev/null 2>&1
}

container_eth0_matches() {
  local identity=$1 pid ip gw
  pid=${PID_BY_ID[$identity]} ip=${WORKLOAD_IP_BY_ID[$identity]} gw=${HOST_IP_BY_ID[$identity]}
  nsenter -t "$pid" -n ip -o -4 addr show dev eth0 2>/dev/null | grep -F " $ip/30 " >/dev/null || return 1
  nsenter -t "$pid" -n ip -4 route show default 2>/dev/null | grep -F "default via $gw dev eth0" >/dev/null || return 1
}

# The desired policy (nft ruleset + routes + resolvers) hashed into the nft
# table comment, so plan/status can tell "converged" from "drift" without a
# state file.
desired_policy_text() {
  render_nft_ruleset
  printf -- '--- routes ---\n'
  render_routes
  printf -- '--- dns ---\n'
  local profile
  for profile in "${PROFILES[@]}"; do
    render_dnsmasq_conf "$profile"
  done
}

desired_policy_hash() { desired_policy_text | cksum | awk '{print $1}'; }

current_policy_hash() {
  ns_exists || { printf '%s\n' none; return; }
  ip netns exec "$ZNS" nft list table inet zts 2>/dev/null \
    | sed -n 's/.*comment "zts-state:\([0-9]*\)".*/\1/p' | head -1 | grep . || printf '%s\n' none
}

# ---------- rendering (pure: no mutation) ----------

transport_route_target() {
  # prints the "via/dev" fragment for routes using transport $1
  local t=$1 kind
  kind=$(transport_type "$t")
  case "$kind" in
    host) printf 'via %s dev %s' "$HOSTLINK_HOST_IP" "$HOSTLINK_NS_IF" ;;
    wireguard) printf 'dev %s' "$(transport_ifname "$t")" ;;
  esac
}

transport_oif() {
  local t=$1 kind
  kind=$(transport_type "$t")
  case "$kind" in
    host) printf '%s' "$HOSTLINK_NS_IF" ;;
    wireguard) transport_ifname "$t" ;;
  esac
}

render_routes() {
  # one line per `ip -n $ZNS route replace ...` argument list, per profile table
  local profile table target_id target_ip target_zif count i resource via cidr name_via
  for profile in "${PROFILES[@]}"; do
    table=${TABLE_BY_PROFILE[$profile]}
    for target_id in "${IDENTITIES[@]}"; do
      target_ip=${WORKLOAD_IP_BY_ID[$target_id]}
      target_zif=${ZIF_BY_ID[$target_id]}
      printf '%s/32 dev %s table %s\n' "$target_ip" "$target_zif" "$table"
    done
    count=$(profile_allow_count "$profile")
    for ((i=0; i<count; i++)); do
      resource=$(allow_field "$profile" "$i" to)
      [[ -z $(resource_workload "$resource") ]] || continue
      via=$(allow_field "$profile" "$i" via)
      while IFS= read -r cidr; do
        [[ -n $cidr ]] || continue
        printf '%s %s metric 100 table %s\n' "$cidr" "$(transport_route_target "$via")" "$table"
      done < <(resource_cidrs "$resource")
    done
    name_via=${NAME_TRANSPORT_BY_PROFILE[$profile]:-}
    if [[ -n $name_via ]]; then
      # Name-based reachability can land on any address; the route is broad,
      # the nftables set is the authorization.
      printf 'default %s metric 200 table %s\n' "$(transport_route_target "$name_via")" "$table"
    fi
    printf 'unreachable default metric 32760 table %s\n' "$table"
  done
}

nft_port_expr() {
  local profile=$1 index=$2 protocol=$3
  local -a ports=()
  local p joined
  while IFS= read -r p; do
    [[ -n $p ]] && ports+=("$p")
  done < <(allow_ports "$profile" "$index")
  ((${#ports[@]} > 0)) || return 0
  if ((${#ports[@]} == 1)); then
    printf '%s dport %s' "$protocol" "${ports[0]}"
  else
    joined=$(IFS=', '; printf '%s' "${ports[*]}")
    printf '%s dport { %s }' "$protocol" "$joined"
  fi
}

render_nft_ruleset() {
  local identity profile zif src count i resource target_id target_ip target_zif
  local via oif cidr protocol pexpr setname name
  local -A sets_done=()

  cat <<'NFT'
add chain inet zts antispoof
add chain inet zts input { type filter hook input priority filter; policy drop; }
add chain inet zts forward { type filter hook forward priority filter; policy drop; }
add rule inet zts input iifname "lo" accept
add rule inet zts input ct state established,related accept
add rule inet zts input jump antispoof
add rule inet zts forward ct state invalid drop
add rule inet zts forward ct state established,related accept
add rule inet zts forward jump antispoof
NFT

  # Bind source identity to the kernel-created ingress interface.
  for identity in "${IDENTITIES[@]}"; do
    zif=${ZIF_BY_ID[$identity]}
    src=${WORKLOAD_IP_BY_ID[$identity]}
    printf 'add rule inet zts antispoof iifname "%s" ip saddr != %s drop\n' "$zif" "$src"
    # DNS to its own gateway only (the per-profile resolver listens there).
    printf 'add rule inet zts input iifname "%s" ip daddr %s meta l4proto { tcp, udp } th dport 53 accept\n' \
      "$zif" "${HOST_IP_BY_ID[$identity]}"
  done

  # Sets for name-based resources (populated by dnsmasq).
  for profile in "${PROFILES[@]}"; do
    count=$(profile_allow_count "$profile")
    for ((i=0; i<count; i++)); do
      resource=$(allow_field "$profile" "$i" to)
      [[ -z ${sets_done[$resource]:-} ]] || continue
      [[ -n $(resource_names "$resource" | head -1) ]] || continue
      sets_done[$resource]=1
      printf 'add set inet zts %s { type ipv4_addr; flags timeout; timeout 1h; }\n' "$(resource_setname "$resource")"
    done
  done

  # Order matters:
  #  1. CIDR relations that explicitly name private space (trusted on purpose)
  #  2. host-transport guard: nothing private, link-local or multicast leaves by the host
  #  3. every other CIDR relation (0.0.0.0/0 included) and name-based relations,
  #     whose addresses are chosen by DNS
  #  4. workload-to-workload relations
  local phase
  for phase in private public; do
    if [[ $phase == public ]] && (( HAS_HOST_TRANSPORT == 1 )) && [[ $HOST_ALLOW_PRIVATE != true ]]; then
      printf 'add rule inet zts forward oifname "%s" ip daddr { %s } drop\n' \
        "$HOSTLINK_NS_IF" "$(printf '%s' "$PRIVATE_RANGES" | sed 's/ /, /g')"
    fi
    for identity in "${IDENTITIES[@]}"; do
      profile=${PROFILE_BY_ID[$identity]}
      zif=${ZIF_BY_ID[$identity]}
      count=$(profile_allow_count "$profile")
      for ((i=0; i<count; i++)); do
        resource=$(allow_field "$profile" "$i" to)
        [[ -z $(resource_workload "$resource") ]] || continue
        via=$(allow_field "$profile" "$i" via)
        oif=$(transport_oif "$via")
        protocol=$(allow_field "$profile" "$i" protocol)
        [[ -n $protocol ]] || protocol=any
        pexpr=""
        [[ $protocol == any ]] || pexpr=$(nft_port_expr "$profile" "$i" "$protocol")
        while IFS= read -r cidr; do
          [[ -n $cidr ]] || continue
          if cidr_is_private "$cidr"; then [[ $phase == private ]] || continue
          else [[ $phase == public ]] || continue; fi
          printf 'add rule inet zts forward iifname "%s" oifname "%s" ip daddr %s' "$zif" "$oif" "$cidr"
          [[ $protocol == any ]] || printf ' meta l4proto %s' "$protocol"
          [[ -z $pexpr ]] || printf ' %s' "$pexpr"
          printf ' accept\n'
        done < <(resource_cidrs "$resource")
      done
    done
  done

  for identity in "${IDENTITIES[@]}"; do
    profile=${PROFILE_BY_ID[$identity]}
    zif=${ZIF_BY_ID[$identity]}
    count=$(profile_allow_count "$profile")
    for ((i=0; i<count; i++)); do
      resource=$(allow_field "$profile" "$i" to)
      target_id=$(resource_workload "$resource")
      protocol=$(allow_field "$profile" "$i" protocol)
      [[ -n $protocol ]] || protocol=any
      pexpr=""
      [[ $protocol == any ]] || pexpr=$(nft_port_expr "$profile" "$i" "$protocol")

      if [[ -n $target_id ]]; then
        target_ip=${WORKLOAD_IP_BY_ID[$target_id]}
        target_zif=${ZIF_BY_ID[$target_id]}
        printf 'add rule inet zts forward iifname "%s" oifname "%s" ip daddr %s' "$zif" "$target_zif" "$target_ip"
        [[ $protocol == any ]] || printf ' meta l4proto %s' "$protocol"
        [[ -z $pexpr ]] || printf ' %s' "$pexpr"
        printf ' accept\n'
        continue
      fi

      [[ -n $(resource_names "$resource" | head -1) ]] || continue
      via=$(allow_field "$profile" "$i" via)
      oif=$(transport_oif "$via")
      setname=$(resource_setname "$resource")
      if resource_names "$resource" | grep -Fx '*' >/dev/null; then
        # "*" means any name: reachability is wide open on this transport
        # for the declared protocol/ports (the host guard still applies).
        printf 'add rule inet zts forward iifname "%s" oifname "%s"' "$zif" "$oif"
      else
        printf 'add rule inet zts forward iifname "%s" oifname "%s" ip daddr @%s' "$zif" "$oif" "$setname"
      fi
      [[ $protocol == any ]] || printf ' meta l4proto %s' "$protocol"
      [[ -z $pexpr ]] || printf ' %s' "$pexpr"
      printf ' accept\n'
    done
  done
}

render_dnsmasq_conf() {
  # dnsmasq config for one profile: listens on that profile's gateways only,
  # resolves only declared names, and feeds resolved addresses into nft sets.
  local profile=$1 identity count i resource name setname r any=0
  local -a listen=()
  for identity in "${IDENTITIES[@]}"; do
    [[ ${PROFILE_BY_ID[$identity]} == "$profile" ]] || continue
    listen+=("${HOST_IP_BY_ID[$identity]}")
  done
  (( ${#listen[@]} > 0 )) || return 0
  [[ -n ${NAME_TRANSPORT_BY_PROFILE[$profile]:-} ]] || return 0

  printf 'port=53\nno-resolv\nno-hosts\nno-poll\nbind-interfaces\nuser=root\ncache-size=1000\n'
  printf 'pid-file=%s/dnsmasq-%s.pid\n' "$RUN_DIR" "$profile"
  printf 'listen-address=%s\n' "$(IFS=,; printf '%s' "${listen[*]}")"
  # Everything is NXDOMAIN unless a declared name says otherwise (longest match wins).
  printf 'local=/#/\n'

  count=$(profile_allow_count "$profile")
  for ((i=0; i<count; i++)); do
    resource=$(allow_field "$profile" "$i" to)
    setname=$(resource_setname "$resource")
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      if [[ $name == '*' ]]; then any=1; continue; fi
      name=${name#\*.}
      for r in $RESOLVERS; do printf 'server=/%s/%s\n' "$name" "$r"; done
      printf 'nftset=/%s/inet#zts#%s\n' "$name" "$setname"
    done < <(resource_names "$resource")
  done
  if (( any == 1 )); then
    for r in $RESOLVERS; do printf 'server=%s\n' "$r"; done
  fi
}

# ---------- plan ----------

print_plan() {
  local changes=0 t ifn kind identity zif desired current

  printf 'ZTS plan for %s\n\n' "$MANIFEST"

  if ns_exists; then
    printf '= namespace %s\n' "$ZNS"
  else
    printf '+ namespace %s\n' "$ZNS"
    changes=1
  fi

  while IFS= read -r t; do
    [[ -n $t ]] || continue
    kind=$(transport_type "$t")
    case "$kind" in
      host)
        if hostlink_exists; then
          printf '= transport %s (host link %s)\n' "$t" "$HOSTLINK_HOST_IF"
        else
          printf '+ transport %s (host link %s)\n' "$t" "$HOSTLINK_HOST_IF"
          changes=1
        fi
        ;;
      wireguard)
        ifn=$(transport_ifname "$t")
        if wg_exists "$ifn"; then
          printf '= transport %s (%s)\n' "$t" "$ifn"
        else
          printf '+ transport %s (%s)\n' "$t" "$ifn"
          changes=1
        fi
        ;;
    esac
  done < <(transport_list)

  for identity in "${IDENTITIES[@]}"; do
    zif=${ZIF_BY_ID[$identity]}
    if zif_exists "$zif" && container_eth0_matches "$identity"; then
      printf '= workload %-24s profile=%s ip=%s\n' \
        "$identity" "${PROFILE_BY_ID[$identity]}" "${WORKLOAD_IP_BY_ID[$identity]}"
    else
      printf '~ workload %-24s profile=%s ip=%s : reconcile endpoint\n' \
        "$identity" "${PROFILE_BY_ID[$identity]}" "${WORKLOAD_IP_BY_ID[$identity]}"
      changes=1
    fi
  done

  if ns_exists; then
    local existing expected
    while IFS= read -r existing; do
      [[ $existing == zt* ]] || continue
      expected=0
      for identity in "${IDENTITIES[@]}"; do
        [[ $existing == "${ZIF_BY_ID[$identity]}" ]] && expected=1 && break
      done
      if (( expected == 0 )); then
        printf -- '- stale endpoint %s\n' "$existing"
        changes=1
      fi
    done < <(ip -n "$ZNS" -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | sort -u)
  fi

  desired=$(desired_policy_hash)
  current=$(current_policy_hash)
  if [[ $desired == "$current" ]]; then
    printf '= policy (routes, nftables, resolvers) %s\n' "$desired"
  else
    printf '~ policy (routes, nftables, resolvers) %s -> %s\n' "$current" "$desired"
    changes=1
  fi

  printf '\n'
  if (( changes )); then
    printf 'Plan contains changes.\n'
  else
    printf 'No changes.\n'
  fi
}

# ---------- reconciliation ----------

ensure_namespace() {
  ns_exists || ns_add
  ip -n "$ZNS" link set lo up
  ip netns exec "$ZNS" sysctl -qw net.ipv4.ip_forward=1
  ip netns exec "$ZNS" sysctl -qw net.ipv4.conf.all.rp_filter=0
  ip netns exec "$ZNS" sysctl -qw net.ipv4.conf.default.rp_filter=0
  ip netns exec "$ZNS" sysctl -qw net.ipv6.conf.all.disable_ipv6=1 || true
  mkdir -p "$RUN_DIR"
}

ensure_host_link() {
  if ! hostlink_exists; then
    ip link del "$HOSTLINK_HOST_IF" 2>/dev/null || true
    ip -n "$ZNS" link del "$HOSTLINK_NS_IF" 2>/dev/null || true
    ip link add "$HOSTLINK_HOST_IF" type veth peer name "$HOSTLINK_NS_IF"
    ip link set "$HOSTLINK_NS_IF" netns "$ZNS"
  fi
  ip addr replace "$HOSTLINK_HOST_IP/30" dev "$HOSTLINK_HOST_IF"
  ip link set "$HOSTLINK_HOST_IF" up
  ip -n "$ZNS" addr replace "$HOSTLINK_NS_IP/30" dev "$HOSTLINK_NS_IF"
  ip -n "$ZNS" link set "$HOSTLINK_NS_IF" up
  # Host: return path for the workload pool; forwarding on.
  ip route replace "$POOL" via "$HOSTLINK_NS_IP" dev "$HOSTLINK_HOST_IF"
  sysctl -qw net.ipv4.ip_forward=1
  sysctl -qw "net.ipv4.conf.$HOSTLINK_HOST_IF.rp_filter=0" 2>/dev/null || true
  # Namespace main table: how the resolvers are reached (dnsmasq upstream).
  ip -n "$ZNS" route replace default via "$HOSTLINK_HOST_IP" dev "$HOSTLINK_NS_IF"

  # Host-side NAT and forwarding for the pool. nft is the mechanism; if Docker
  # manages iptables with a DROP policy on FORWARD, its DOCKER-USER chain is
  # the documented place to let our link through.
  nft -f - <<NFT
table inet zts_host {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr { $POOL, $HOSTLINK_NS_IP } oifname != "$HOSTLINK_HOST_IF" masquerade
  }
  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    iifname "$HOSTLINK_HOST_IF" accept
    oifname "$HOSTLINK_HOST_IF" ct state established,related accept
  }
}
NFT
  local ipt
  ipt=$(docker_user_iptables) || return 0
  "$ipt" -C DOCKER-USER -i "$HOSTLINK_HOST_IF" -j ACCEPT 2>/dev/null || \
    "$ipt" -I DOCKER-USER 1 -i "$HOSTLINK_HOST_IF" -j ACCEPT
  "$ipt" -C DOCKER-USER -o "$HOSTLINK_HOST_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    "$ipt" -I DOCKER-USER 1 -o "$HOSTLINK_HOST_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

# Docker keeps a DROP policy on FORWARD and documents DOCKER-USER as the chain
# for user rules. It may live in the nft or the legacy xtables backend; pick
# the one where the chain actually exists.
docker_user_iptables() {
  local b
  for b in iptables-nft iptables-legacy iptables; do
    command -v "$b" >/dev/null 2>&1 || continue
    "$b" -S DOCKER-USER >/dev/null 2>&1 || continue
    printf '%s\n' "$b"
    return 0
  done
  return 1
}

remove_host_link() {
  local ipt
  if ipt=$(docker_user_iptables); then
    "$ipt" -D DOCKER-USER -i "$HOSTLINK_HOST_IF" -j ACCEPT 2>/dev/null || true
    "$ipt" -D DOCKER-USER -o "$HOSTLINK_HOST_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  fi
  nft delete table inet zts_host 2>/dev/null || true
  ip link del "$HOSTLINK_HOST_IF" 2>/dev/null || true
}

ensure_wireguard_transport() {
  local t=$1 ifn addr keyfile pub endpoint keepalive allowed_csv old_peer
  ifn=$(transport_ifname "$t")
  addr=$(transport_field "$t" '.address')
  keyfile=$(transport_field "$t" '.private_key_file')
  pub=$(transport_field "$t" '.peer.public_key')
  endpoint=$(transport_field "$t" '.peer.endpoint')
  keepalive=$(transport_field "$t" '.peer.persistent_keepalive // 0')

  [[ -r $keyfile ]] || die "transport '$t': cannot read private key file '$keyfile'"

  if ! wg_exists "$ifn"; then
    # Create in the host namespace, then move it. WireGuard keeps its UDP
    # socket in the namespace where the interface was created, while plaintext
    # traffic exists only in the ZTS namespace.
    ip link show "$ifn" >/dev/null 2>&1 && die "host interface '$ifn' already exists"
    ip link add "$ifn" type wireguard
    ip link set "$ifn" netns "$ZNS"
  fi

  ip -n "$ZNS" addr flush dev "$ifn" scope global
  ip -n "$ZNS" addr add "$addr" dev "$ifn"

  while IFS= read -r old_peer; do
    [[ -n $old_peer ]] || continue
    [[ $old_peer == "$pub" ]] || ip netns exec "$ZNS" wg set "$ifn" peer "$old_peer" remove
  done < <(ip netns exec "$ZNS" wg show "$ifn" peers 2>/dev/null || true)

  allowed_csv=$(transport_allowed_ips "$t" | paste -sd, -)
  ip netns exec "$ZNS" wg set "$ifn" \
    private-key "$keyfile" \
    peer "$pub" allowed-ips "$allowed_csv" endpoint "$endpoint" persistent-keepalive "$keepalive"
  ip -n "$ZNS" link set "$ifn" up
}

ensure_transport() {
  local t=$1
  case "$(transport_type "$t")" in
    host) ensure_host_link ;;
    wireguard) ensure_wireguard_transport "$t" ;;
  esac
}

cleanup_stale_endpoints() {
  local existing expected identity
  while IFS= read -r existing; do
    [[ $existing == zt* ]] || continue
    expected=0
    for identity in "${IDENTITIES[@]}"; do
      if [[ $existing == "${ZIF_BY_ID[$identity]}" ]]; then
        expected=1
        break
      fi
    done
    if (( expected == 0 )); then
      info "remove stale endpoint $existing"
      ip -n "$ZNS" link del "$existing" || true
    fi
  done < <(ip -n "$ZNS" -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | sort -u)
}

write_container_resolv() {
  # The container's resolv.conf is a file on the Docker host that Docker
  # bind-mounts into the container. Pointing it at the workload's gateway
  # makes the per-profile resolver the only name source. No exec inside the
  # container, so the image does not need a shell.
  local identity=$1 path
  path=${RESOLV_BY_ID[$identity]}
  [[ -n $path ]] || { warn "$identity: no ResolvConfPath from Docker; names will not resolve"; return 0; }
  path="$HOST_ROOT$path"
  if [[ ! -e $path ]]; then
    warn "$identity: resolv.conf not reachable at $path; names will not resolve"
    return 0
  fi
  printf 'nameserver %s\noptions ndots:0\n' "${HOST_IP_BY_ID[$identity]}" > "$path"
}

ensure_endpoint() {
  local identity=$1 pid zif tmp host_ip workload_ip
  pid=${PID_BY_ID[$identity]}
  zif=${ZIF_BY_ID[$identity]}
  host_ip=${HOST_IP_BY_ID[$identity]}
  workload_ip=${WORKLOAD_IP_BY_ID[$identity]}
  tmp="c${zif#zt}"

  if zif_exists "$zif" && container_eth0_matches "$identity"; then
    ip -n "$ZNS" link set "$zif" up
    write_container_resolv "$identity"
    return 0
  fi

  if zif_exists "$zif"; then
    ip -n "$ZNS" link del "$zif" || true
  fi

  if nsenter -t "$pid" -n ip link show eth0 >/dev/null 2>&1; then
    die "$identity: eth0 exists but is not attached to the expected ZTS endpoint; refusing to replace it"
  fi

  ip link add "$zif" type veth peer name "$tmp"
  ip link set "$zif" netns "$ZNS"
  ip link set "$tmp" netns "$pid"

  ip -n "$ZNS" addr add "$host_ip/30" dev "$zif"
  ip -n "$ZNS" link set "$zif" up

  nsenter -t "$pid" -n ip link set lo up
  nsenter -t "$pid" -n ip link set "$tmp" name eth0
  nsenter -t "$pid" -n ip addr add "$workload_ip/30" dev eth0
  nsenter -t "$pid" -n ip link set eth0 up
  nsenter -t "$pid" -n ip route replace default via "$host_ip" dev eth0
  nsenter -t "$pid" -n sysctl -qw net.ipv6.conf.all.disable_ipv6=1 || true
  write_container_resolv "$identity"
}

reset_zts_policy_rules() {
  local pref table
  # The namespace belongs entirely to ZTS. Remove only rules at our dedicated
  # priority, flushing their referenced tables first.
  while read -r pref table; do
    [[ -n $pref ]] || continue
    ip -n "$ZNS" route flush table "$table" 2>/dev/null || true
    ip -n "$ZNS" rule del pref "$pref" 2>/dev/null || true
  done < <(
    ip -n "$ZNS" rule show | \
      awk -v p="$RULE_PREF" '$1 == p":" {for(i=1;i<=NF;i++) if($i=="lookup") print p, $(i+1)}'
  )
}

reconcile_policy_routing() {
  local identity ip table line
  reset_zts_policy_rules
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    # shellcheck disable=SC2086
    ip -n "$ZNS" route replace $line
  done < <(render_routes)
  for identity in "${IDENTITIES[@]}"; do
    table=${TABLE_BY_PROFILE[${PROFILE_BY_ID[$identity]}]}
    ip=${WORKLOAD_IP_BY_ID[$identity]}
    ip -n "$ZNS" rule add pref "$RULE_PREF" from "$ip/32" lookup "$table"
  done
}

reconcile_nftables() {
  local tmp hash
  tmp=$(mktemp)
  hash=$(desired_policy_hash)
  {
    ip netns exec "$ZNS" nft list table inet zts >/dev/null 2>&1 && printf 'delete table inet zts\n'
    printf 'add table inet zts { comment "zts-state:%s"; }\n' "$hash"
    render_nft_ruleset
  } >"$tmp"
  # nft applies a file as one transaction: the policy swap is atomic.
  ip netns exec "$ZNS" nft -f "$tmp"
  rm -f "$tmp"
}

reconcile_resolvers() {
  local profile conf pidfile pid
  mkdir -p "$RUN_DIR"
  # Stop resolvers for profiles that no longer exist.
  for pidfile in "$RUN_DIR"/dnsmasq-*.pid; do
    [[ -e $pidfile ]] || continue
    profile=${pidfile##*/dnsmasq-}; profile=${profile%.pid}
    if [[ -z ${NAME_TRANSPORT_BY_PROFILE[$profile]:-} ]]; then
      pid=$(cat "$pidfile" 2>/dev/null || true)
      [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
      rm -f "$pidfile" "$RUN_DIR/dnsmasq-$profile.conf"
    fi
  done
  for profile in "${PROFILES[@]}"; do
    [[ -n ${NAME_TRANSPORT_BY_PROFILE[$profile]:-} ]] || continue
    conf="$RUN_DIR/dnsmasq-$profile.conf"
    pidfile="$RUN_DIR/dnsmasq-$profile.pid"
    render_dnsmasq_conf "$profile" > "$conf.new"
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && cmp -s "$conf" "$conf.new"; then
      rm -f "$conf.new"
      continue
    fi
    [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
    mv "$conf.new" "$conf"
    ip netns exec "$ZNS" dnsmasq --conf-file="$conf" || die "profile '$profile': dnsmasq failed to start"
  done
}

verify_state() {
  local identity profile table ip zif
  ns_exists || die "verification: namespace '$ZNS' missing"
  ip netns exec "$ZNS" nft list table inet zts >/dev/null 2>&1 || die "verification: nft table missing"
  for identity in "${IDENTITIES[@]}"; do
    zif=${ZIF_BY_ID[$identity]}
    zif_exists "$zif" || die "verification: endpoint '$zif' missing"
    container_eth0_matches "$identity" || die "verification: '$identity' container endpoint mismatch"
    profile=${PROFILE_BY_ID[$identity]}
    table=${TABLE_BY_PROFILE[$profile]}
    ip=${WORKLOAD_IP_BY_ID[$identity]}
    ip -n "$ZNS" rule show | grep -F "from $ip lookup $table" >/dev/null || die "verification: '$identity' policy rule missing"
  done
  [[ $(desired_policy_hash) == "$(current_policy_hash)" ]] || die "verification: policy hash mismatch"
}

apply_state() {
  local t identity
  ensure_namespace
  if (( HAS_HOST_TRANSPORT == 0 )); then
    remove_host_link
  fi
  while IFS= read -r t; do
    [[ -n $t ]] || continue
    info "reconcile transport $t"
    ensure_transport "$t"
  done < <(transport_list)

  cleanup_stale_endpoints
  for identity in "${IDENTITIES[@]}"; do
    info "reconcile workload $identity"
    ensure_endpoint "$identity"
  done

  info "reconcile routing"
  reconcile_policy_routing
  info "reconcile nftables"
  reconcile_nftables
  info "reconcile resolvers"
  reconcile_resolvers
  verify_state
  info "converged (${#IDENTITIES[@]} workload(s))"
}

print_status() {
  local identity zif profile table t ifn kind state
  printf 'namespace: %s\n' "$ZNS"
  printf 'state:     %s\n' "$(ns_exists && echo present || echo absent)"
  printf 'pool:      %s\n' "$POOL"
  if [[ $(desired_policy_hash) == "$(current_policy_hash)" ]]; then
    printf 'policy:    converged\n\n'
  else
    printf 'policy:    drift\n\n'
  fi

  printf 'workloads:\n'
  if ((${#IDENTITIES[@]} == 0)); then
    printf '  (none)\n'
  else
    for identity in "${IDENTITIES[@]}"; do
      zif=${ZIF_BY_ID[$identity]}
      profile=${PROFILE_BY_ID[$identity]}
      table=${TABLE_BY_PROFILE[$profile]}
      if zif_exists "$zif" && container_eth0_matches "$identity"; then state=converged; else state=drift; fi
      printf '  %-24s profile=%-16s ip=%-15s endpoint=%-12s table=%s state=%s\n' \
        "$identity" "$profile" "${WORKLOAD_IP_BY_ID[$identity]}" "$zif" "$table" "$state"
    done
  fi

  printf '\ntransports:\n'
  local found=0
  while IFS= read -r t; do
    [[ -n $t ]] || continue
    found=1
    kind=$(transport_type "$t")
    case "$kind" in
      host)
        printf '  %-24s type=host      interface=%-12s state=%s\n' "$t" "$HOSTLINK_HOST_IF" \
          "$(hostlink_exists && echo present || echo missing)" ;;
      wireguard)
        ifn=$(transport_ifname "$t")
        printf '  %-24s type=wireguard interface=%-12s state=%s\n' "$t" "$ifn" \
          "$(wg_exists "$ifn" && echo present || echo missing)" ;;
    esac
  done < <(transport_list)
  (( found )) || printf '  (none)\n'
}

destroy_state() {
  local pidfile pid
  for pidfile in "$RUN_DIR"/dnsmasq-*.pid; do
    [[ -e $pidfile ]] || continue
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  done
  rm -f "$RUN_DIR"/dnsmasq-*.conf
  remove_host_link
  if ns_exists; then
    info "delete namespace $ZNS (all ZTS veth/WireGuard/kernel state disappears with it)"
    ns_del
  else
    info "namespace $ZNS already absent"
  fi
}

# ---------- up: reconcile on container events ----------

reconcile_once() {
  # Fresh manifest and inventory every time; everything above is idempotent.
  HAS_HOST_TRANSPORT=0; HOST_ALLOW_PRIVATE=false
  validate_manifest
  IDENTITIES=(); PROFILES=()
  CID_BY_ID=(); PID_BY_ID=(); PROFILE_BY_ID=(); HOST_IP_BY_ID=(); WORKLOAD_IP_BY_ID=()
  ZIF_BY_ID=(); RESOLV_BY_ID=(); ID_BY_SLOT=(); TABLE_BY_PROFILE=(); PROFILE_BY_TABLE=()
  NAME_TRANSPORT_BY_PROFILE=()
  discover_workloads
  validate_desired_graph
  apply_state
}

run_up() {
  local line since
  if [[ ! -f $MANIFEST && -n ${ZTS_PRESET:-} ]]; then
    run_init >/dev/null
  fi
  [[ -f $MANIFEST ]] || die "manifest not found: $MANIFEST (run '$PROGRAM init' first, or set ZTS_PRESET)"
  info "up: reconciling and watching container events (manifest: $MANIFEST)"
  # Events are requested from just before each reconcile, so a container that
  # starts while we are busy (or before the stream is connected) is replayed
  # by Docker instead of being missed.
  since=$(date +%s)
  ( reconcile_once ) || warn "initial reconcile failed; will retry on the next event"
  local mtime rc
  mtime=$(stat -c %Y "$MANIFEST" 2>/dev/null || echo 0)
  while :; do
    # The stream ends when Docker restarts; reconnect from where we left off.
    # Between events, a changed manifest is applied within a couple of seconds.
    while :; do
      if IFS= read -r -t 2 line; then
        [[ -n $line ]] || continue
        info "event: $line"
        since=$(date +%s)
        ( reconcile_once ) || warn "reconcile failed; will retry on the next event"
      else
        rc=$?
        (( rc > 128 )) || break
      fi
      if [[ $(stat -c %Y "$MANIFEST" 2>/dev/null || echo 0) != "$mtime" ]]; then
        mtime=$(stat -c %Y "$MANIFEST" 2>/dev/null || echo 0)
        info "manifest changed: $MANIFEST"
        since=$(date +%s)
        ( reconcile_once ) || warn "manifest rejected; the previous state stays applied"
      fi
    done < <(curl -sN --unix-socket "$DOCKER_SOCK" -G 'http://docker/events' \
               --data-urlencode "since=$since" \
               --data-urlencode 'filters={"type":["container"],"event":["start","die"],"label":["zts.profile"]}' \
               | jq --unbuffered -r '"\(.Action) \(.Actor.Attributes.name // .Actor.ID[0:12])"' 2>/dev/null)
    warn "event stream closed; reconnecting in 2s"
    sleep 2
  done
}

# ---------- init: presets ----------

preset_manifest() {
  local preset=$1
  cat <<'HEAD'
# ZTS manifest. Profiles declare what a workload may reach; nothing else exists.
# Attach a container with:  docker run --network none --label zts.profile=<profile> ...
version: 1

substrate:
  namespace: zts
  pool: 100.64.0.0/10

transports:
  # Egress through this host's own default route. Private and link-local
  # destinations are never reachable this way unless a resource lists a CIDR.
  host:
    type: host

HEAD
  case "$preset" in
    coding-agent) cat <<'YAML'
resources:
  github:
    names: [github.com, "*.github.com", "*.githubusercontent.com"]
  package-registries:
    names:
      - registry.npmjs.org
      - pypi.org
      - files.pythonhosted.org
      - proxy.golang.org
      - sum.golang.org
      - crates.io
      - "*.crates.io"
  model-apis:
    names: [api.anthropic.com, api.openai.com]

profiles:
  isolated:
    allow: []

  dev:
    allow:
      - { to: github,             via: host, protocol: tcp, ports: [443] }
      - { to: package-registries, via: host, protocol: tcp, ports: [443] }
      - { to: model-apis,         via: host, protocol: tcp, ports: [443] }
YAML
      ;;
    web-dev) cat <<'YAML'
resources:
  # Any name, any public address, web ports only. Host, LAN and link-local
  # stay unreachable (see transports.host).
  internet:
    names: ["*"]

profiles:
  isolated:
    allow: []

  dev:
    allow:
      - { to: internet, via: host, protocol: tcp, ports: [80, 443] }
YAML
      ;;
    isolated) cat <<'YAML'
resources: {}

profiles:
  isolated:
    allow: []
YAML
      ;;
    *) die "unknown preset '$preset' (coding-agent, web-dev, isolated)" ;;
  esac
}

run_init() {
  local preset=${ZTS_PRESET:-} answer
  if [[ -e $MANIFEST && ${ZTS_FORCE:-0} != 1 ]]; then
    info "manifest already exists: $MANIFEST (set ZTS_FORCE=1 to overwrite)"
    return 0
  fi
  if [[ -z $preset ]]; then
    if [[ -t 0 ]]; then
      printf '\nWhat will these containers mostly do?\n\n' >&2
      printf '  1) run coding agents   github, package registries and model APIs, port 443 only\n' >&2
      printf '  2) web development     any public name on ports 80 and 443\n' >&2
      printf '  3) nothing             no network at all\n\n' >&2
      printf 'Pick 1, 2 or 3 [1]: ' >&2
      read -r answer
      case "${answer:-1}" in
        1) preset=coding-agent ;;
        2) preset=web-dev ;;
        3) preset=isolated ;;
        *) die "pick 1, 2 or 3" ;;
      esac
    else
      die "no TTY and ZTS_PRESET unset (coding-agent, web-dev, isolated)"
    fi
  fi
  mkdir -p "$(dirname "$MANIFEST")"
  preset_manifest "$preset" > "$MANIFEST"
  info "wrote $MANIFEST (preset: $preset)"
  printf '%s\n' "$MANIFEST"
}

# ---------- selftest (pure, no root, no network) ----------

selftest() {
  local gw ip slot ifn wg table
  read -r gw ip slot < <(endpoint_for_identity 'example/workload' '100.64.0.0/10')
  validate_ipv4 "$gw" || die "selftest: invalid gateway"
  validate_ipv4 "$ip" || die "selftest: invalid workload ip"
  [[ $gw != "$ip" ]] || die "selftest: endpoint addresses collide"

  ifn=$(endpoint_ifname 'example/workload')
  wg=$(transport_ifname 'example-egress')
  table=$(profile_table 'development')
  ((${#ifn} <= 15)) || die "selftest: endpoint ifname too long"
  ((${#wg} <= 15)) || die "selftest: wg ifname too long"
  (( table >= TABLE_MIN && table < TABLE_MIN + TABLE_SPAN )) || die "selftest: routing table out of range"
  ((${#HOSTLINK_HOST_IF} <= 15)) || die "selftest: host link ifname too long"

  validate_cidr '0.0.0.0/0' || die "selftest: /0 validation failed"
  validate_cidr '100.64.0.0/10' || die "selftest: pool validation failed"
  ! validate_cidr '999.1.1.1/32' || die "selftest: invalid IP accepted"
  validate_name 'github.com' || die "selftest: name rejected"
  validate_name '*.github.com' || die "selftest: wildcard name rejected"
  validate_name '*' || die "selftest: any-name rejected"
  ! validate_name 'not a name' || die "selftest: invalid name accepted"
  ! validate_name 'localhost' || die "selftest: single-label name accepted"
  cidr_is_private '192.168.1.0/24' || die "selftest: private cidr not detected"
  cidr_is_private '10.0.0.5/32' || die "selftest: private host not detected"
  ! cidr_is_private '0.0.0.0/0' || die "selftest: /0 treated as private"
  ! cidr_is_private '8.8.8.0/24' || die "selftest: public cidr treated as private"

  local p
  for p in coding-agent web-dev isolated; do
    preset_manifest "$p" | yq -e '.version == 1 and (.profiles.isolated.allow | length) == 0' >/dev/null \
      || die "selftest: preset '$p' is not a valid manifest"
  done

  printf 'selftest ok: %s -> gateway=%s workload=%s slot=%s endpoint=%s wg=%s table=%s\n' \
    'example/workload' "$gw" "$ip" "$slot" "$ifn" "$wg" "$table"
}

main() {
  case "$COMMAND" in
    selftest) need_cmd yq; selftest; exit 0 ;;
    check) need_cmd yq; check_manifest; exit 0 ;;
    show) run_show; exit 0 ;;
    load) need_cmd yq; run_load; exit 0 ;;
    edit) need_cmd yq; run_edit; exit $? ;;
    init) run_init; exit 0 ;;
    plan|apply|status|destroy|up) ;;
    -h|--help|help|'') usage; exit 0 ;;
    *) usage >&2; die "unknown command '$COMMAND'" ;;
  esac

  require_root
  require_runtime_deps
  setup_host_mode
  if [[ $COMMAND == up && ! -f $MANIFEST && -n ${ZTS_PRESET:-} ]]; then
    run_init >/dev/null
  fi
  validate_manifest

  # Serialize reconcilers. This is not a daemon/state service; it only prevents
  # two one-shot applies from editing the same kernel objects concurrently.
  mkdir -p /run/lock
  exec 9>"/run/lock/zts-${ZNS}.lock"
  flock -x 9

  case "$COMMAND" in
    destroy) destroy_state; exit 0 ;;
    up) run_up; exit 0 ;;
  esac

  discover_workloads
  validate_desired_graph

  case "$COMMAND" in
    plan)    print_plan ;;
    apply)   apply_state ;;
    status)  print_status ;;
  esac
}

main "$@"
