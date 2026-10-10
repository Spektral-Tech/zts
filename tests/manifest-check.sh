#!/usr/bin/env bash
# Manifest validation without root: runs validate_manifest + the pure graph
# checks by sourcing zts.sh with a stubbed Docker inventory.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ok=0; bad=0
BASH4=${BASH4:-bash}
expect() { # expect ok|fail <manifest>
  local want=$1 m=$2 out rc=0
  out=$("$BASH4" ./zts.sh check "$m" 2>&1) || rc=$?
  if [[ $want == ok && $rc -eq 0 ]] || [[ $want == fail && $rc -ne 0 ]]; then
    echo "ok   $want $m"; ok=$((ok+1))
  else
    echo "FAIL expected $want for $m (rc=$rc): $out"; bad=$((bad+1))
  fi
}
expect ok   zts.example.yaml
for f in tests/fixtures/valid-*.yaml;   do expect ok   "$f"; done
for f in tests/fixtures/invalid-*.yaml; do expect fail "$f"; done
echo "manifest checks: $ok ok, $bad failed"
(( bad == 0 ))
