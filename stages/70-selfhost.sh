#!/bin/bash
# Stage 70 - make the package manager manage itself.
#
# Everything up to here was installed straight into /usr by make/ninja, because
# there was no package manager to install it properly.  That leaves rpm, dnf5 and
# their libraries owned by nothing: dnf cannot upgrade dnf, and `rpm -V` cannot
# tell you whether librpm has been tampered with.
#
# The build trees are still on disk and already compiled, so this re-runs each
# install step with DESTDIR and packages the result.  No recompilation.
. "$(dirname "$0")/../lib/common.sh"
REPACK="$(cd "$(dirname "$0")/../tools" && pwd)/bf-repack"
BF_LOCALREPO="${BF_LOCALREPO:-/srv/blackflag/repo/local}"

# Optional components whose dependencies are not present on BlackFlag.  Upstream
# distributions ship these as separate subpackages (git-svn, git-cvs, git-p4) for
# exactly this reason: they pull in perl(SVN::Core), perl(DBI), perl(CGI) and a
# /usr/bin/python that BlackFlag does not have.  Shipping them anyway would make
# the git package uninstallable.
GIT_EXCLUDE="/usr/libexec/git-core/git-svn
/usr/libexec/git-core/git-cvsserver
/usr/libexec/git-core/git-cvsimport
/usr/libexec/git-core/git-cvsexportcommit
/usr/libexec/git-core/git-archimport
/usr/libexec/git-core/git-instaweb
/usr/libexec/git-core/git-p4
/usr/bin/git-cvsserver
/usr/share/perl5/Git/SVN
/usr/share/perl5/Git/SVN.pm
/usr/share/gitweb"

# name | version | build subdirectory | install command
PKGS=(
  "curl|8.15.0|curl-8.15.0|make install"
  "elfutils|0.193|elfutils-0.193|make install"
  "sdbus-cpp|2.1.0|sdbus-cpp-2.1.0|ninja -C build install"
  "git|2.51.0|git-2.51.0|make NO_TCLTK=1 install"
  "pcre2|10.45|pcre2-10.45|make install"
  "cmake|3.31.6|cmake-3.31.6|ninja install"
  "libxml2|2.13.8|libxml2-2.13.8|make install"
  "swig|4.3.1|swig-4.3.1|make install"
  "libgpg-error|1.55|libgpg-error-1.55|make install"
  "libgcrypt|1.11.1|libgcrypt-1.11.1|make install"
  "libassuan|3.0.2|libassuan-3.0.2|make install"
  "libksba|1.6.7|libksba-1.6.7|make install"
  "npth|1.8|npth-1.8|make install"
  "gnupg|2.4.8|gnupg-2.4.8|make install"
  "gpgme|1.24.3|gpgme-1.24.3|make install"
  "rpm|4.19.1.1|rpm-4.19.1.1|make -C _build install"
  "libyaml|0.2.5|yaml-0.2.5|make install"
  "glib2|2.84.4|glib-2.84.4|ninja -C build install"
  "json-c|0.18|json-c-json-c-0.18-20240915|ninja -C build install"
  "zchunk|1.5.1|zchunk-1.5.1|ninja -C build install"
  "fmt|11.1.4|fmt-11.1.4|ninja -C build install"
  "spdlog|1.15.1|spdlog-1.15.1|ninja -C build install"
  "toml11|4.4.0|toml11-4.4.0|ninja -C build install"
  "libsolv|0.7.32|libsolv-0.7.32|ninja -C build install"
  "librepo|1.20.0|librepo-1.20.0|ninja -C build install"
  "libcomps|0.1.21|libcomps-0.1.21/libcomps|ninja -C build install"
  "libmodulemd|2.15.2|libmodulemd-libmodulemd-2.15.2|ninja -C build install"
  "dnf5|5.2.13.0|dnf5-5.2.13.0|ninja -C build install"
  "createrepo_c|1.2.1|createrepo_c-1.2.1|ninja -C build install"
)

built=0 skipped=0
for entry in "${PKGS[@]}"; do
    IFS='|' read -r name ver sub cmd <<<"$entry"
    d="$BF_BUILD/$sub"
    if [ ! -d "$d" ]; then warn "no build tree for $name ($sub) - skipping"; skipped=$((skipped+1)); continue; fi
    if done_already "repack-$name"; then ok "$name (cached)"; continue; fi
    msg "repacking $name $ver"
    local excl=""
    [ "$name" = "git" ] && excl="$GIT_EXCLUDE"
    if BF_REPACK_EXCLUDE="$excl" $REPACK "$name" "$ver" "$d" $cmd >>"$BF_LOGS/repack.log" 2>&1; then
        mark_done "repack-$name"; built=$((built+1)); ok "$name"
    else
        warn "$name failed - see $BF_LOGS/repack.log"; skipped=$((skipped+1))
    fi
done

msg "repacked $built, skipped $skipped"

if [ "$built" -gt 0 ]; then
    msg "publishing to $BF_LOCALREPO"
    "$(dirname "$REPACK")/bf-repo" add "$BF_LOCALREPO" /root/rpmbuild/RPMS/*/*.rpm \
        || warn "publish failed"
fi

cat <<'EOF'

The bootstrap stack is now RPM content.  Take ownership of the already-installed
copies without touching the files on disk:

    rpm -Uvh --replacefiles --replacepkgs /root/rpmbuild/RPMS/*/*.rpm

Then verify:

    rpm -qf $(command -v dnf5)
    rpm -V rpm
    bf-lfs-audit
EOF
msg "stage 70 complete"
