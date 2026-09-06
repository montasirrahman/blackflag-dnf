# BlackFlag DNF bootstrap - shared build helpers.  Sourced by stage scripts.
set -u

BF_ROOT="${BF_ROOT:-/root/blackflag}"
BF_SRC="${BF_SRC:-$BF_ROOT/src}"
BF_BUILD="${BF_BUILD:-$BF_ROOT/build}"
BF_LOGS="${BF_LOGS:-$BF_ROOT/logs}"
BF_STAMPS="${BF_STAMPS:-$BF_ROOT/work/stamps}"
BF_JOBS="${BF_JOBS:-$(nproc)}"
mkdir -p "$BF_BUILD" "$BF_LOGS" "$BF_STAMPS"

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_C='\033[0;36m'; C_B='\033[1m'; C_N='\033[0m'
msg()  { echo -e "${C_C}==>${C_N} $*"; }
ok()   { echo -e "${C_G} ok ${C_N} $*"; }
warn() { echo -e "${C_Y} !! ${C_N} $*"; }
die()  { echo -e "${C_R}FAIL${C_N} $*" >&2; exit 1; }

# done_already <name> -> 0 if the stamp exists (build can be skipped)
done_already() { [ -f "$BF_STAMPS/$1" ]; }
mark_done()    { touch "$BF_STAMPS/$1"; }

# unpack <tarball-glob> <expected-dir>   echoes the source dir
unpack() {
    local glob="$1" dir="$2" tb
    tb=$(ls "$BF_SRC"/$glob 2>/dev/null | head -1) || true
    [ -n "${tb:-}" ] && [ -f "$tb" ] || die "source tarball not found: $glob"
    rm -rf "${BF_BUILD:?}/$dir"
    tar -xf "$tb" -C "$BF_BUILD" || die "extract failed: $tb"
    [ -d "$BF_BUILD/$dir" ] || die "expected dir missing after extract: $dir"
    echo "$BF_BUILD/$dir"
}

# run <logname> <cmd...>  - run a build step, tee-ing to a log, abort on failure
run() {
    local log="$BF_LOGS/$1.log"; shift
    if ! "$@" >>"$log" 2>&1; then
        echo -e "${C_R}--- last 30 lines of $log ---${C_N}" >&2
        tail -30 "$log" >&2
        die "step failed: $* (see $log)"
    fi
}

# apply_patches <srcdir> <prefix>  - apply patches/<prefix>*.patch, in sorted order
apply_patches() {
    local d="$1" prefix="$2" p
    local pdir="${BF_PATCHES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/patches}"
    [ -d "$pdir" ] || return 0
    for p in $(ls "$pdir/${prefix}"*.patch 2>/dev/null | sort); do
        msg "  patch: $(basename "$p")"
        patch -d "$d" -p1 -N -r - --no-backup-if-mismatch < "$p" >/dev/null 2>&1 \
            || warn "  patch did not apply cleanly (may already be applied): $(basename "$p")"
    done
}

# build_pkg <stamp> <tarball-glob> <srcdir> <builder-function>
build_pkg() {
    local stamp="$1" glob="$2" dir="$3" fn="$4" d
    if done_already "$stamp"; then ok "$stamp (cached)"; return 0; fi
    msg "building $stamp"
    : > "$BF_LOGS/$stamp.log"
    d=$(unpack "$glob" "$dir")
    apply_patches "$d" "$dir"
    ( cd "$d" && "$fn" "$d" ) || die "$stamp"
    ldconfig
    mark_done "$stamp"
    ok "$stamp"
}
