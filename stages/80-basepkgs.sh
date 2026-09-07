#!/bin/bash
# Stage 80 - convert the LFS base system into real RPMs, one package at a time.
#
#   ./80-basepkgs.sh            tier 1 only (the default, and the safe one)
#   ./80-basepkgs.sh 1 2        tiers 1 and 2
#   BF_INSTALL=0 ./80-basepkgs.sh   build and package, but do not install
#
# See docs/ARCHITECTURE.md section 5(C).  The goal is to raise the fraction of the
# filesystem that rpm actually owns, so `rpm -qf`, `rpm -V` and clean upgrades all
# start working on base components -- and so blackflag-base can eventually retire.
#
# Two rules this script enforces, because getting either wrong is expensive:
#
#   1. Versions must MATCH what is installed.  This records what is already on the
#      machine; it is not an upgrade.  Doing both at once means a breakage cannot
#      be attributed to either.  The manifest carries the installed versions, and
#      each build is checked against the running system where that is possible.
#
#   2. Tier 3 is refused.  glibc, gcc, binutils, systemd, the kernel, perl and
#      python cannot be swapped under a running system with `rpm -U`; that needs an
#      offline transaction or a separate build host.
. "$(dirname "$0")/../lib/common.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$HERE/packaging/base-packages.list"
REPACK="$HERE/tools/bf-repack"
BF_INSTALL="${BF_INSTALL:-1}"
BF_LOCALREPO="${BF_LOCALREPO:-/srv/blackflag/repo/local}"
TIERS="${*:-1}"

# A conversion run replaces files on a live system.  Refuse to start without a
# rollback snapshot -- restoring one is the difference between a ten-minute
# recovery and a rebuild.
SNAPSHOT="${BF_SNAPSHOT:-$BF_ROOT/backup/pre-basepkgs-usr-etc.tar.zst}"
if [ "${BF_INSTALL:-1}" = "1" ] && [ ! -s "$SNAPSHOT" ]; then
    die "no rollback snapshot at $SNAPSHOT.  Create one first:
     mkdir -p $(dirname "$SNAPSHOT")
     tar -I 'zstd -3 -T2' -cf $SNAPSHOT /usr /etc /var/lib/rpm
     ...or set BF_INSTALL=0 to build and package without installing."
fi

case " $TIERS " in *" 3 "*)
    die "tier 3 (glibc, gcc, binutils, systemd, kernel, perl, python) cannot be
     converted by replacing files on a running system.  Build them on a separate
     host, or apply them through an offline transaction." ;;
esac

# ------------------------------------------------------- installed-version check
# A conversion records what is on the machine.  If the manifest version does not
# match what is installed, building it would be an upgrade (or a downgrade, or --
# as with grep and find here -- a substitution of an entirely different program),
# and a breakage afterwards could not be attributed to either change.
#
# Probe the BINARY, by absolute path, never the name.  An interactive shell can
# have functions or aliases shadowing a command -- development tooling in
# particular likes to wrap grep and find -- and asking such a shell what is
# installed gives you the wrapper's version, not the system's.  Scripts do not
# inherit those functions, so the two disagree, and the interactive answer is the
# misleading one.
probe_version() {
    case "$1" in
      gzip)      /usr/bin/gzip --version ;;    tar)       /usr/bin/tar --version ;;
      diffutils) /usr/bin/diff --version ;;    patch)     /usr/bin/patch --version ;;
      sed)       /usr/bin/sed --version ;;     m4)        /usr/bin/m4 --version ;;
      make)      /usr/bin/make --version ;;    grep)      /usr/bin/grep --version ;;
      findutils) /usr/bin/find --version ;;    file)      /usr/bin/file --version ;;
      sqlite)    /usr/bin/sqlite3 --version ;; xz)        /usr/bin/xz --version ;;
      zstd)      /usr/bin/zstd --version ;;    bzip2)     /usr/bin/bzip2 --version 2>&1 ;;
      *)         return 1 ;;
    esac 2>/dev/null | head -1 | /usr/bin/grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

check_version() {
    local name="$1" want="$2" have
    have=$(probe_version "$name") || return 0      # nothing to compare against
    [ -n "$have" ] || return 0
    if [ "$have" != "$want" ]; then
        warn "$name: manifest says $want but $have is installed - SKIPPING"
        warn "     converting it would be an upgrade or a substitution, not a conversion"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- build recipes
# Anything not named here uses the plain autotools path.  Where a package needs
# different flags than upstream's default, the reason is stated.
recipe() {
    local name="$1" ver="$2" d="$3"
    case "$name" in
      zlib)      ./configure --prefix=/usr ;;
      bzip2)     # bzip2 ships no configure; the shared library needs a separate pass.
                 sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
                 sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
                 make -f Makefile-libbz2_so -j"$BF_JOBS" && make clean && return 0 ;;
      zstd)      return 0 ;;   # plain make, no configure
      lz4)       return 0 ;;
      libcap)    return 0 ;;
      file)      ./configure --prefix=/usr ;;
      readline)  # Two things here are not optional.
                 #
                 # 1. readline's shared library only links ncurses if SHLIB_LIBS
                 #    says so (see build_cmd).  --with-curses alone affects the
                 #    static link, not the .so, and a readline without ncurses
                 #    resolves none of the termcap symbols (UP, BC, PC) its callers
                 #    need -- it installs cleanly and breaks everything after.
                 # 2. readline's install renames the previous library to .old
                 #    instead of removing it.  Two files then share a SONAME,
                 #    ldconfig may point the .so.N symlink at the .old one, and
                 #    deleting the backup later orphans the link.  LFS strips that
                 #    behaviour out; so do we.
                 sed -i '/MV.*old/d' Makefile.in
                 sed -i '/{OLDSUFF}/c:' support/shlib-install
                 ./configure --prefix=/usr --disable-static --with-curses \
                     --docdir=/usr/share/doc/readline-"$ver" ;;
      ncurses)   ./configure --prefix=/usr --mandir=/usr/share/man --with-shared \
                     --without-debug --without-normal --with-cxx-shared --enable-pc-files ;;
      sqlite)    # SQLITE_ENABLE_COLUMN_METADATA is what provides
                 # sqlite3_column_database_name and its six siblings.  Without it the
                 # rebuild silently drops seven public API symbols that the installed
                 # library exports, and anything using them fails to link or resolve.
                 ./configure --prefix=/usr --disable-static --enable-fts4 --enable-fts5 \
                     CPPFLAGS="-DSQLITE_ENABLE_COLUMN_METADATA=1 \
                               -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 \
                               -DSQLITE_ENABLE_DBSTAT_VTAB=1 \
                               -DSQLITE_SECURE_DELETE=1" ;;
      gmp)       # GCC 15 defaults to C23, where "void g(){}" declares a function
                 # taking NO arguments rather than an unspecified list.  gmp 6.3.0's
                 # compiler probe calls such a function with six arguments, so it
                 # fails to compile and configure concludes -- wrongly -- that there
                 # is no working compiler at all.  Pin the probe and the build to
                 # C17 semantics.
                 #
                 # --host=none-linux-gnu disables gmp's CPU auto-detection.  gmp
                 # otherwise tunes itself to the build machine and picks different
                 # assembly paths, which changes which symbols exist: the installed
                 # copy exports __gmpn_clz_tab (the generic leading-zero table) and a
                 # host-tuned rebuild does not.  Building generic is what matches, and
                 # is what a distributable library should be anyway.
                 CFLAGS="${CFLAGS:-} -std=gnu17" CXXFLAGS="${CXXFLAGS:-} -std=gnu17" \
                 ./configure --prefix=/usr --enable-cxx --disable-static \
                     --host=none-linux-gnu ;;
      mpfr)      ./configure --prefix=/usr --disable-static --enable-thread-safe ;;
      libxcrypt) ./configure --prefix=/usr --enable-hashes=strong,glibc \
                     --enable-obsolete-api=no --disable-static --disable-failure-tokens ;;
      libarchive)# libarchive uses either libxml2 or expat for xar support, preferring
                 # libxml2 when it is present.  libxml2 did not exist on this system
                 # when LFS built libarchive, so the installed copy links expat -- but
                 # the bootstrap installed libxml2 since, and an unqualified rebuild
                 # now silently switches.  Pin it to what is actually installed.
                 ./configure --prefix=/usr --disable-static --without-xml2 ;;
      attr)      ./configure --prefix=/usr --disable-static --sysconfdir=/etc \
                     --docdir=/usr/share/doc/attr-"$ver" ;;
      acl)       ./configure --prefix=/usr --disable-static \
                     --docdir=/usr/share/doc/acl-"$ver" ;;
      tar)       # tar's configure aborts under root because its "can mknod a fifo
                 # without privileges" probe is meaningless when you always can.
                 # LFS sets the same override.
                 FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr ;;
      make|m4|sed|gzip|diffutils|patch|grep|findutils)
                 ./configure --prefix=/usr ;;
      *)         ./configure --prefix=/usr --disable-static ;;
    esac
}

build_cmd() {
    case "$1" in
      readline) echo "make -j$BF_JOBS SHLIB_LIBS=-lncursesw" ;;
      zstd)   echo "make -j$BF_JOBS PREFIX=/usr" ;;
      lz4)    echo "make -j$BF_JOBS PREFIX=/usr" ;;
      libcap) echo "make -j$BF_JOBS prefix=/usr lib=lib" ;;
      bzip2)  echo "make -j$BF_JOBS -f Makefile-libbz2_so" ;;
      *)      echo "make -j$BF_JOBS" ;;
    esac
}

# @BUILDROOT@ is substituted by bf-repack with the staging directory.  It is
# required for build systems that honour no DESTDIR at all -- bzip2's Makefile has
# no DESTDIR in it whatsoever, so a plain `make install PREFIX=/usr` writes into
# the live /usr.  bf-repack's tripwire catches that now, but the right answer is
# to stage it properly rather than rely on the tripwire.
install_cmd() {
    case "$1" in
      zstd)   echo "make install PREFIX=@BUILDROOT@/usr" ;;
      lz4)    echo "make install PREFIX=@BUILDROOT@/usr" ;;
      libcap) echo "make install prefix=/usr lib=lib" ;;
      bzip2)  echo "make install PREFIX=@BUILDROOT@/usr" ;;
      *)      echo "make install" ;;
    esac
}

# -------------------------------------------------------------------- main loop
built=0 failed=0 skipped=0
while IFS='|' read -r tier name ver url; do
    case "$tier" in ''|\#*) continue;; esac
    case " $TIERS " in *" $tier "*) ;; *) continue;; esac
    done_already "base-$name" && { ok "$name (cached)"; continue; }

    if ! check_version "$name" "$ver"; then skipped=$((skipped+1)); continue; fi
    msg "converting $name $ver (tier $tier)"
    tb="$BF_SRC/$(basename "$url")"
    if [ ! -s "$tb" ]; then
        wget -q -O "$tb" "$url" || { warn "$name: download failed"; rm -f "$tb"; failed=$((failed+1)); continue; }
    fi

    dir=$(tar tf "$tb" 2>/dev/null | head -1 | cut -d/ -f1)
    [ -n "$dir" ] || { warn "$name: cannot read tarball"; failed=$((failed+1)); continue; }
    rm -rf "${BF_BUILD:?}/$dir"
    tar -xf "$tb" -C "$BF_BUILD" || { warn "$name: extract failed"; failed=$((failed+1)); continue; }
    d="$BF_BUILD/$dir"

    L="$BF_LOGS/base-$name.log"; : > "$L"
    if ! ( cd "$d" && recipe "$name" "$ver" "$d" >>"$L" 2>&1 && eval "$(build_cmd "$name")" >>"$L" 2>&1 ); then
        warn "$name: build failed - see $L"; failed=$((failed+1)); continue
    fi

    if ! $REPACK "$name" "$ver" "$d" $(install_cmd "$name") >>"$L" 2>&1; then
        warn "$name: packaging failed - see $L"; failed=$((failed+1)); continue
    fi

    rpmfile=$(ls -t /root/rpmbuild/RPMS/*/"$name"-"$ver"-*.rpm 2>/dev/null | head -1)
    [ -n "$rpmfile" ] || { warn "$name: no rpm produced"; failed=$((failed+1)); continue; }

    # Gate: a rebuild whose configure flags differ from the original produces a
    # library that packages cleanly and then breaks its consumers at run time.
    # Compare against what is on disk before replacing anything.
    if ! "$HERE/tools/bf-abi-check" "$rpmfile" >>"$L" 2>&1; then
        warn "$name: ABI regression against the installed copy - NOT installing"
        "$HERE/tools/bf-abi-check" "$rpmfile" 2>&1 | sed 's/^/      /' | head -8
        failed=$((failed+1)); continue
    fi

    if [ "$BF_INSTALL" = "1" ]; then
        if rpm -Uvh --replacefiles --replacepkgs "$rpmfile" >>"$L" 2>&1; then
            # A broken libz or libpopt takes rpm itself down.  Check immediately,
            # while it is still obvious which package did it.
            if ! rpm --version >/dev/null 2>&1 || ! dnf5 --version >/dev/null 2>&1; then
                die "$name broke rpm or dnf5 - restore from the snapshot in backup/ and investigate"
            fi
            ok "$name installed and rpm/dnf5 still work"
        else
            warn "$name: install failed - see $L"; failed=$((failed+1)); continue
        fi
    else
        ok "$name packaged (not installed)"
    fi
    mark_done "base-$name"
    built=$((built+1))
done < "$MANIFEST"

msg "converted $built, failed $failed, skipped $skipped"
[ "$built" -gt 0 ] && "$HERE/tools/bf-repo" add "$BF_LOCALREPO" /root/rpmbuild/RPMS/*/*.rpm >/dev/null 2>&1
"$HERE/tools/bf-lfs-audit" | sed -n '1,12p'
