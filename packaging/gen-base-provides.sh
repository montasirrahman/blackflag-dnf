#!/bin/bash
# Derive the Provides: list for the blackflag-base shim package from the live system.
# See docs/ARCHITECTURE.md §5(A).  Emits one "Provides: ..." line per finding on stdout.
set -u
LIBDIRS="/usr/lib /usr/lib64 /lib /lib64"

emit() { printf 'Provides:       %s\n' "$1"; }

# --- 1. shared-library sonames, in rpm's dependency form ------------------------------
{
for d in $LIBDIRS; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -name '*.so.*' -printf '%f\n' 2>/dev/null
done
} | grep -E '\.so\.[0-9]' | sed -E 's/(\.so\.[0-9]+)\..*/\1/' | sort -u | while read -r so; do
    emit "${so}()(64bit)"
done

# --- 2. pkg-config modules ------------------------------------------------------------
for d in $LIBDIRS /usr/share/pkgconfig; do
    [ -d "$d/pkgconfig" ] && d="$d/pkgconfig"
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -name '*.pc' -printf '%f\n' 2>/dev/null
done | sed 's/\.pc$//' | sort -u | while read -r pc; do
    emit "pkgconfig(${pc})"
done

# --- 3. base package names, versioned where the version can be probed -----------------
# probe: <rpm-name>|<command producing a version>|<sed/awk to extract>
while IFS='|' read -r name cmd; do
    case "$name" in ''|\#*) continue;; esac
    v=""
    [ -n "$cmd" ] && v=$(eval "$cmd" 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
    if [ -n "$v" ]; then emit "${name} = ${v}-0.bf1"; else emit "${name}"; fi
done <<'PROBES'
glibc|ldd --version
bash|bash --version
coreutils|/usr/bin/ls --version
gcc|gcc -dumpfullversion
gcc-c++|gcc -dumpfullversion
binutils|ld --version
make|make --version
perl|perl -e 'print substr($^V,1)' 2>/dev/null || perl -v
python3|python3 -V
systemd|systemctl --version
util-linux|mount --version
grep|grep --version
sed|sed --version
gawk|gawk --version
tar|tar --version
gzip|gzip --version
xz|xz --version
zstd|zstd --version
bzip2|bzip2 --version 2>&1
findutils|find --version
diffutils|diff --version
patch|patch --version
file|file --version
which|
shadow|
openssl|openssl version
zlib|
sqlite|sqlite3 --version
readline|
ncurses|
expat|
popt|
libarchive|
elfutils|
libcap|
acl|attr|
gettext|gettext --version
pkgconf|pkgconf --version
autoconf|autoconf --version
automake|automake --version
libtool|libtool --version
bison|bison --version
flex|flex --version
m4|m4 --version
meson|meson --version
ninja-build|ninja --version
wget|wget --version
vim|
kmod|kmod --version
procps-ng|ps --version
psmisc|
iproute|
dbus|
e2fsprogs|
filesystem|
setup|
PROBES
