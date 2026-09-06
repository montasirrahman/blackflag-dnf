#!/bin/bash
# Derive the Provides: list for the blackflag-base shim from the live system.
# See docs/ARCHITECTURE.md section 5(A).  One "Provides: ..." line per finding.
#
# rpm's automatic dependency generator does not stop at bare sonames.  For any
# binary it packages it also emits:
#   - versioned symbol deps   libc.so.6(GLIBC_2.34)(64bit)
#   - the loader hash style   rtld(GNU_HASH)
#   - file dependencies       /usr/bin/pkg-config
# A shim that provides only sonames therefore satisfies almost nothing, and every
# install fails on dependencies the base system plainly has.  This emits all four
# kinds, read from the system rather than hand-listed.
set -u
LIBDIRS="/usr/lib /usr/lib64 /lib /lib64"
BINDIRS="/usr/bin /usr/sbin /bin /sbin"
MARK="(64bit)"

emit() { printf 'Provides:       %s\n' "$1"; }

# --- 1. shared-library sonames, and their exported symbol versions -------------
# Read DT_SONAME from the ELF rather than guessing it from the filename.  Guessing
# is wrong often enough to matter: libbz2.so.1.0.8 has SONAME libbz2.so.1.0, not
# libbz2.so.1, and liblua.so.5.4.8 has liblua.so.5.4.  A wrong soname provides
# something nothing asks for while the real dependency stays unsatisfied.
soname_of() {
    readelf -d "$1" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p' | head -1
}

{
for d in $LIBDIRS; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -name '*.so*' -type f -print 2>/dev/null
done
} | sort -u | while read -r lib; do
    son=$(soname_of "$lib")
    # Some libraries are linked without a SONAME at all -- sqlite3 on this system
    # is one -- and consumers then record the bare link name in DT_NEEDED.
    [ -n "$son" ] || son=$(basename "$lib")
    echo "SONAME|${son}|"
    readelf -V "$lib" 2>/dev/null \
        | awk '/Version definition section/,/Version needs section/' \
        | grep -oE 'Name: [A-Za-z0-9_.+-]+' | sed 's/Name: //' \
        | grep -vFx "$son" | grep -vFx "$(basename "$lib")" | sort -u \
        | while read -r v; do echo "SYMVER|${son}|${v}"; done
done | sort -u | while IFS='|' read -r kind so ver; do
    case "$kind" in
        SONAME) emit "${so}()${MARK}" ;;
        SYMVER) emit "${so}(${ver})${MARK}" ;;
    esac
done

# A .so symlink whose target carries no SONAME is itself the name consumers use,
# so it has to be provided under its own name too.
for d in $LIBDIRS; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -name '*.so*' -type l -print 2>/dev/null
done | sort -u | while read -r link; do
    tgt=$(readlink -f "$link") || continue
    [ -f "$tgt" ] || continue
    [ -n "$(soname_of "$tgt")" ] && continue
    emit "$(basename "$link")()${MARK}"
done

# --- 2. the dynamic loader's hash style ---------------------------------------
# Every ELF binary rpm packages requires this; glibc's loader supplies it.
emit "rtld(GNU_HASH)"

# --- 3. pkg-config modules ----------------------------------------------------
for d in $LIBDIRS /usr/share; do
    [ -d "$d/pkgconfig" ] || continue
    find "$d/pkgconfig" -maxdepth 1 -name '*.pc' -printf '%f\n' 2>/dev/null
done | sed 's/\.pc$//' | sort -u | while read -r pc; do
    emit "pkgconfig(${pc})"
done

# --- 4. file dependencies -----------------------------------------------------
# Scripts get a Requires on their interpreter path, and specs commonly require a
# tool by path.  Anything already owned by a real RPM is left out, so this list
# shrinks as base packages are converted.
owned=$(mktemp); trap 'rm -f "$owned"' EXIT
rpm -qal 2>/dev/null | sort -u > "$owned"
for d in $BINDIRS; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 \( -type f -o -type l \) -print 2>/dev/null
done | sort -u | comm -23 - "$owned" | while read -r f; do
    emit "$f"
done
# /bin and /sbin are symlinks to their /usr counterparts on a merged-usr system,
# but scripts still say #!/bin/sh, so provide those paths too.
for f in /bin/sh /bin/bash /usr/bin/env; do
    [ -e "$f" ] && ! grep -qxF "$f" "$owned" && emit "$f"
done

# --- 4b. perl modules ---------------------------------------------------------
# rpm's perl dependency generator turns "use Foo::Bar;" into Requires: perl(Foo::Bar),
# so git and friends need every core module named that way.
if command -v perl >/dev/null 2>&1; then
    perl -MConfig -e 'print "$Config{privlib}\n$Config{archlib}\n"' 2>/dev/null \
      | sort -u | while read -r d; do
        [ -d "$d" ] || continue
        ( cd "$d" && find . -name '*.pm' -type f -printf '%P\n' 2>/dev/null )
    done | sed -e 's/\.pm$//' -e 's#/#::#g' | sort -u | while read -r m; do
        emit "perl(${m})"
    done
    pv=$(perl -e 'printf "%vd", $^V' 2>/dev/null)
    [ -n "$pv" ] && emit "perl(:MODULE_COMPAT_${pv})"
fi

# --- 5. base package names, versioned where the version can be probed ---------
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
libstdc++|gcc -dumpfullversion
binutils|ld --version
make|make --version
perl|perl -v
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
libcap|
acl|
attr|
gettext|gettext --version
pkgconf|pkgconf --version
pkgconfig|pkgconf --version
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
