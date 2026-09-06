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
      sqlite)    ./configure --prefix=/usr --disable-static --enable-fts4 --enable-fts5 ;;
      gmp)       ./configure --prefix=/usr --enable-cxx --disable-static ;;
      mpfr)      ./configure --prefix=/usr --disable-static --enable-thread-safe ;;
      libxcrypt) ./configure --prefix=/usr --enable-hashes=strong,glibc \
                     --enable-obsolete-api=no --disable-static --disable-failure-tokens ;;
      libarchive)./configure --prefix=/usr --disable-static ;;
      attr)      ./configure --prefix=/usr --disable-static --sysconfdir=/etc \
                     --docdir=/usr/share/doc/attr-"$ver" ;;
      acl)       ./configure --prefix=/usr --disable-static \
                     --docdir=/usr/share/doc/acl-"$ver" ;;
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
