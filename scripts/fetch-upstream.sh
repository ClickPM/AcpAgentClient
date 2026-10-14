#!/usr/bin/env bash
# Populate or verify vendor/upstream/ from pins/upstream.json.
#   scripts/fetch-upstream.sh          fetch missing repos at their pinned commit, verify existing ones
#   scripts/fetch-upstream.sh --check  verify only (exit 1 on any missing or drifted repo)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$ROOT/pins/upstream.json"
DEST="$ROOT/vendor/upstream"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
mkdir -p "$DEST"
PYTHON_BIN=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import json,sys; assert sys.version_info[0]>=3" >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v "$cand")"
    break
  fi
done
if [ -z "$PYTHON_BIN" ]; then
  echo "error: no working python/python3 interpreter found" >&2
  exit 1
fi
UPSTREAMS="$("$PYTHON_BIN" -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); [print(u['name'],u['url'],u['commit']) for u in d['upstream']]" "$PINS" | tr -d '\r')"
if [ -z "$UPSTREAMS" ]; then
  echo "error: no upstream entries read from $PINS" >&2
  exit 1
fi
fail=0
while read -r name url sha; do
  dir="$DEST/$name"
  head=""
  if [ -d "$dir/.git" ]; then
    head="$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)"
  fi
  if [ -n "$head" ]; then
    if [ "$head" = "$sha" ]; then
      echo "OK      $name @ ${sha:0:12}"
    else
      echo "DRIFT   $name: HEAD ${head:0:12} != pinned ${sha:0:12}"
      fail=1
    fi
  elif [ "$CHECK" = 1 ]; then
    echo "MISSING $name"
    fail=1
  else
    echo "FETCH   $name @ ${sha:0:12} ..."
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    git -C "$dir" fetch -q --depth 1 origin "$sha"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    echo "DONE    $name"
  fi
done <<< "$UPSTREAMS"
exit $fail
