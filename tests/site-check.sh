#!/usr/bin/env bash
# Static site checks: no broken relative links when served from site/, no
# leftover expansion of the name, copies in sync with the root documents.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
fail=0
while IFS= read -r href; do
  [[ $href == \#* || $href == http* || $href == mailto:* ]] && continue
  f=${href%%#*}; f=${f%%\?*}
  [[ -e "site/$f" ]] || { echo "broken link in site/index.html: $href"; fail=1; }
done < <(grep -o 'href="[^"]*"' site/index.html | sed 's/href="//;s/"$//')
[[ -e site/manifesto.html ]] && { echo "site/manifesto.html must not exist: the manifesto lives on the home page"; fail=1; }
if grep -ril 'zero trust substrate' site/ >/dev/null; then
  echo "site still says 'Zero Trust Substrate'"; fail=1
fi
node web/build.mjs --check || fail=1
for page in site/spec.html site/reference.html; do
  while IFS= read -r href; do
    [[ $href == \#* || $href == http* ]] && continue
    f=${href%%#*}; f=${f%%\?*}
    [[ -e "site/$f" ]] || { echo "broken link in $page: $href"; fail=1; }
  done < <(grep -o 'href="[^"]*"' "$page" | sed 's/href="//;s/"$//')
done
if [[ -e site/brand-mark.png ]]; then
  size=$(wc -c < site/brand-mark.png)
  (( size <= 80000 )) || { echo "site/brand-mark.png is $size bytes (max 80000)"; fail=1; }
fi
# Static assets are cache-busted by content hash.
h=$(shasum -a 256 site/styles.css 2>/dev/null | cut -c1-10 || sha256sum site/styles.css | cut -c1-10)
grep -q "styles.css?v=$h" site/index.html site/spec.html || { echo "stylesheet link does not carry the content hash $h"; fail=1; }

# The quickstart on the site must be the commands two-minutes.sh runs.
norm() { sed 's/<[^>]*>//g; s/^\$ //; s/\\$//; s/^ *//; s/"\$IMAGE"/ghcr.io\/spektral-tech\/zts/; s/\$TTY/-it/; s/\${ZTS_PRESET:+-e ZTS_PRESET} //' | grep -E '^(docker run|-v )' | tr -s ' ' | sed 's/ *$//'; }
site_cmds=$(python3 -I -c 'import re,html;s=open("site/index.html").read();m=re.search(r"<pre id=\"quickstart\">(.*?)</pre>",s,re.S);print(html.unescape(re.sub(r"<[^>]*>","",m.group(1))))' | norm)
script_cmds=$(norm < scripts/two-minutes.sh | grep -v 'zts.profile=isolated')
if [[ "$site_cmds" != "$script_cmds" ]]; then
  echo "quickstart on the site differs from scripts/two-minutes.sh"; printf -- '--- site\n%s\n--- script\n%s\n' "$site_cmds" "$script_cmds"; fail=1
fi
(( fail == 0 )) && echo "site checks ok"
exit $fail
