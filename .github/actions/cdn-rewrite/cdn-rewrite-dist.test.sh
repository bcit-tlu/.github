#!/usr/bin/env bash
# Behavioural test for cdn-rewrite-dist.sh: run the rewrite against a fixture
# dist/ containing quoted AND unquoted HTML asset attributes (minified
# production output) and verify every relative reference is rewritten.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

pass() { printf 'PASS: %s\n' "$1"; }
err() {
  printf 'FAIL: %s\n' "$1" >&2
  fail=1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/dist"
cat > "${tmp}/dist/index.html" <<'EOF'
<!doctype html><html lang=en><head><link rel=icon type=image/x-icon href=/favicon.ico><title>t</title><script defer src=main_bundle.js></script><link rel="stylesheet" href="./style.css"></head><body><img src='/bcit_rev.png'><a href="https://example.org/x.png">ext</a></body></html>
EOF
echo 'const a="/bcit_rev.png";' > "${tmp}/dist/main_bundle.js"
echo 'body{background:url(/bcit_rev.png)}' > "${tmp}/dist/style.css"

CDN_URL="https://cdn.example/course-workload-estimator/abc1234" \
ASSET_EXTENSIONS="css,js,ico,png" \
DIST_DIR="${tmp}/dist" \
  bash "${SCRIPT_DIR}/cdn-rewrite-dist.sh"

check() {
  if grep -qF "$2" "$1"; then
    pass "$(basename "$1") contains: $2"
  else
    err "$(basename "$1") missing: $2"
  fi
}

check "${tmp}/dist/index.html" 'href="https://cdn.example/course-workload-estimator/abc1234/favicon.ico"'
check "${tmp}/dist/index.html" 'src="https://cdn.example/course-workload-estimator/abc1234/main_bundle.js"'
check "${tmp}/dist/index.html" 'href="https://cdn.example/course-workload-estimator/abc1234/style.css"'
check "${tmp}/dist/index.html" "src='https://cdn.example/course-workload-estimator/abc1234/bcit_rev.png'"
check "${tmp}/dist/index.html" 'href="https://example.org/x.png"'
check "${tmp}/dist/main_bundle.js" '"https://cdn.example/course-workload-estimator/abc1234/bcit_rev.png"'
check "${tmp}/dist/style.css" 'url(https://cdn.example/course-workload-estimator/abc1234/bcit_rev.png)'

exit "${fail}"
