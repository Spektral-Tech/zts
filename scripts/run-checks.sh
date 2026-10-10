#!/usr/bin/env bash
# The single verification. CI runs exactly this.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
fail=0
step() { printf '\n== %s\n' "$*"; }
BASH4=bash
if (( BASH_VERSINFO[0] < 4 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x $b ]] && BASH4=$b && break; done
fi

step "bash -n"
bash -n zts.sh scripts/*.sh tests/acceptance/*.sh || fail=1

step "shellcheck"
if command -v shellcheck >/dev/null; then
  shellcheck -S warning zts.sh scripts/*.sh tests/acceptance/*.sh || fail=1
else
  echo "skip: shellcheck not installed"
fi

step "selftest (bash >= 4)"
if "$BASH4" -c '(( BASH_VERSINFO[0] >= 4 ))'; then
  "$BASH4" ./zts.sh selftest || fail=1
else
  echo "skip: no bash >= 4 found"
fi

step "selftest guard (bash 3.2 must fail cleanly)"
if [[ -x /bin/bash ]] && /bin/bash -c '(( BASH_VERSINFO[0] < 4 ))'; then
  out=$(/bin/bash ./zts.sh selftest 2>&1 || true)
  grep -q 'requires bash' <<<"$out" || { echo "guard missing: $out"; fail=1; }
else
  echo "skip: no bash 3.x here"
fi

step "manifest fixtures"
if command -v yq >/dev/null; then
  BASH4=$BASH4 tests/manifest-check.sh || fail=1
else
  echo "skip: yq not installed"
fi

step "go (when a toolchain is present)"
if command -v go >/dev/null; then
  test -z "$(gofmt -l cmd internal)" || { echo "gofmt:"; gofmt -l cmd internal; fail=1; }
  go vet ./... || fail=1
  go build -o /dev/null ./cmd/zts || fail=1
  go test ./... || fail=1
  go run ./cmd/zts selftest || fail=1
  # Both implementations must agree on names and addresses.
  if "$BASH4" -c '(( BASH_VERSINFO[0] >= 4 ))'; then
    diff <("$BASH4" ./zts.sh selftest) <(go run ./cmd/zts selftest) || { echo "selftest parity: bash vs go differ"; fail=1; }
  fi
else
  echo "skip: go not installed"
fi

step "site build (node)"
if command -v node >/dev/null && command -v pnpm >/dev/null; then
  [[ -d node_modules ]] || pnpm install --frozen-lockfile --silent || fail=1
  node web/build.mjs --check || fail=1
else
  echo "skip: node + pnpm not installed (site/ is committed; verify in CI)"
fi

step "site"
tests/site-check.sh || fail=1

step "version alignment"
v=$(cat VERSION)
grep -q "Draft $v" SPEC.md || { echo "SPEC.md status is not Draft $v"; fail=1; }
grep -q "ZTS / v$v" site/index.html || { echo "site hero is not v$v"; fail=1; }
grep -q "^Status: v$v" README.md || { echo "README status is not v$v"; fail=1; }
test -s LICENSE && grep -q "Apache License" LICENSE || { echo "LICENSE missing"; fail=1; }

step "acceptance (root + nft + docker only)"
if [[ ${EUID:-$(id -u)} -eq 0 ]] && command -v nft >/dev/null && [[ -S /var/run/docker.sock ]]; then
  tests/acceptance/run.sh || fail=1
else
  echo "skip: needs root, nft and docker (run in the lab VM or CI)"
fi

if (( fail )); then printf '\nCHECKS FAILED\n'; exit 1; fi
printf '\nall checks passed\n'
