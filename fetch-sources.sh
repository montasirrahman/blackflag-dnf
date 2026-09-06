#!/bin/bash
# Download all sources listed in sources.list into src/
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${BF_SRC:-/root/blackflag/src}"
mkdir -p "$SRC"; cd "$SRC" || exit 1
fail=0
while IFS='|' read -r stage name ver url; do
    case "$stage" in ''|\#*) continue;; esac
    [ -n "${1:-}" ] && [ "$stage" != "$1" ] && continue
    f="$(basename "$url")"
    case "$f" in
        [0-9]*.tar.gz|v[0-9]*.tar.gz) f="${name}-${ver}.tar.gz" ;;
    esac
    if [ -s "$f" ]; then echo "  have  $f"; continue; fi
    echo "  fetch $f"
    if ! wget -q -O "$f" "$url"; then
        echo "  FAIL  $name $ver  <- $url"; rm -f "$f"; fail=$((fail+1))
    fi
done < "$HERE/sources.list"
echo "done (failures: $fail)"
exit $fail
