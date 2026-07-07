#!/bin/zsh
set -e
cd "${0:A:h}/.."    # repo root (zsh)
# build the executable
swift build -c release 2>&1 >/dev/null
BIN=".build/release/mcrysden"
if [ ! -x "$BIN" ]; then
  echo "smoke: build failed"; exit 1
fi
"$BIN" Sources/MolVisAppTests/Fixtures/si110.xsf /dev/null --export /tmp/mcrysden_smoke.png
test -s /tmp/mcrysden_smoke.png && echo "OK: smoke.png produced ($(wc -c < /tmp/mcrysden_smoke.png) bytes)"
