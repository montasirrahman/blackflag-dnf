#!/bin/bash
# Stage 60 - make the freshly built rpm/dnf5 usable as BlackFlag's package manager:
# distro rpm macros, a signing key, the blackflag-release package, repo definitions,
# and the rpmdb seed described in docs/ARCHITECTURE.md section 5.
. "$(dirname "$0")/../lib/common.sh"
PKGDIR="$(cd "$(dirname "$0")/../packaging" && pwd)"

BF_RELEASEVER="${BF_RELEASEVER:-1.0}"
BF_DIST="${BF_DIST:-.bf1}"
BF_VENDOR="BlackFlag Linux"
BF_KEY_UID="BlackFlag Linux Package Signing Key <security@blackflag.com.bd>"
BF_KEYFILE=/etc/pki/rpm-gpg/RPM-GPG-KEY-blackflag-1.0
BF_LOCALREPO="${BF_LOCALREPO:-/srv/blackflag/repo/local}"

# ---------------------------------------------------------------- rpm macros
s60_macros() {
    # Location matters.  rpm's macro path is:
    #   /usr/lib/rpm/macros -> macros.d/macros.* -> platform/<target>/macros
    #   -> /usr/lib/rpm/<vendor>/macros -> /etc/rpm/macros.* -> /etc/rpm/macros
    # macros.d is read BEFORE the platform file, so anything set there that the
    # platform also sets (notably %_lib) is overwritten again.  The vendor
    # directory -- which exists because rpm was built with RPM_VENDOR=blackflag --
    # is read after, and is the correct home for distribution macros.
    install -d /usr/lib/rpm/blackflag /etc/rpm /etc/pki/rpm-gpg
    rm -f /usr/lib/rpm/macros.d/macros.blackflag
    cat > /usr/lib/rpm/blackflag/macros <<EOF
# BlackFlag Linux distribution macros
%_vendor                blackflag
%_vendor_name           $BF_VENDOR
%blackflag_version      $BF_RELEASEVER
%dist                   $BF_DIST
%bf1                    1
%distribution           $BF_VENDOR $BF_RELEASEVER
%vendor                 $BF_VENDOR
%packager               BlackFlag Build System <build@blackflag.com.bd>
%bugurl                 https://blackflag.com.bd/bugs
%_buildhost             build.blackflag.com.bd

# BlackFlag inherits LFS's layout: there is no /usr/lib64, and /lib64 holds only
# the ld-linux symlinks the ELF interpreter path requires.  Every real library
# lives in /usr/lib.  rpm's x86_64 platform macros default %_lib to lib64, so
# without this override every library package would install into a directory
# that is not on the linker path and nothing would resolve at runtime.
%_lib                   lib
%_libdir                %{_exec_prefix}/%{_lib}

# Compression: zstd for payloads - fast to decompress, small, and supported
# by every tool in this stack (rpm, libsolv, createrepo_c).
%_source_payload        w19.zstdio
%_binary_payload        w19.zstdio
%_source_filedigest_algorithm  8
%_binary_filedigest_algorithm  8

# Signing
%_gpg_name              $BF_KEY_UID
%_gpg_path              /root/.gnupg
%_signature             gpg

# Build tree under ~/rpmbuild (the upstream default, spelled out for clarity)
%_topdir                %{getenv:HOME}/rpmbuild
%_smp_mflags            -j%(nproc)
EOF
    # Prove the override actually took, rather than assuming it did.
    if [ "$(rpm --eval '%{_libdir}')" != "/usr/lib" ]; then
        die "%_libdir is $(rpm --eval '%{_libdir}'), expected /usr/lib - macro file is being overridden"
    fi
    ok "macros -> /usr/lib/rpm/blackflag/macros (%_libdir=$(rpm --eval '%{_libdir}'))"
}

# ---------------------------------------------------------------- signing key
s60_gpgkey() {
    export GNUPGHOME=/root/.gnupg
    install -d -m700 "$GNUPGHOME"
    if gpg --list-keys "$BF_KEY_UID" >/dev/null 2>&1; then
        ok "signing key already present"
    else
        msg "generating package signing key (RSA 4096, no passphrase - build automation)"
        cat > "$BF_BUILD/bf-key.batch" <<EOF
%echo Generating BlackFlag package signing key
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: BlackFlag Linux Package Signing Key
Name-Email: security@blackflag.com.bd
Expire-Date: 0
%no-protection
%commit
%echo done
EOF
        gpg --batch --gen-key "$BF_BUILD/bf-key.batch" >>"$BF_LOGS/seed.log" 2>&1 || return 1
    fi
    install -d /etc/pki/rpm-gpg
    gpg --armor --export "$BF_KEY_UID" > "$BF_KEYFILE" || return 1
    rpmkeys --import "$BF_KEYFILE" >>"$BF_LOGS/seed.log" 2>&1 || true
    ok "signing key exported -> $BF_KEYFILE"
}

# ---------------------------------------------------------------- dnf config
s60_dnfconf() {
    install -d /etc/dnf/vars /etc/dnf/protected.d /etc/dnf/plugins /etc/yum.repos.d /var/lib/dnf
    [ -e /etc/dnf/repos.d ] || ln -sfn /etc/yum.repos.d /etc/dnf/repos.d
    echo "$BF_RELEASEVER" > /etc/dnf/vars/releasever
    cat > /etc/dnf/dnf.conf <<'EOF'
[main]
gpgcheck=1
installonly_limit=3
clean_requirements_on_remove=True
best=True
skip_if_unavailable=False
keepcache=False
max_parallel_downloads=8
fastestmirror=True
# BlackFlag ships no i686 multilib set; do not let dnf consider foreign arches.
exclude_from_weak_deps=False
EOF
    # dnf must never be talked into removing the things that make the box bootable.
    cat > /etc/dnf/protected.d/blackflag.conf <<'EOF'
blackflag-release
blackflag-base
systemd
glibc
bash
kernel
rpm
dnf5
EOF
    ok "dnf configured (releasever=$BF_RELEASEVER)"
}

# ---------------------------------------------------------------- local repo
s60_localrepo() {
    install -d "$BF_LOCALREPO/Packages"
    createrepo_c --quiet --update "$BF_LOCALREPO" >>"$BF_LOGS/seed.log" 2>&1 || return 1
    cat > /etc/yum.repos.d/blackflag-local.repo <<EOF
# Developer / offline repository.  Drop RPMs into $BF_LOCALREPO/Packages
# then run:  bf-repo-update local
[blackflag-local]
name=BlackFlag Linux \$releasever - Local (\$basearch)
baseurl=file://$BF_LOCALREPO
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$BF_KEYFILE
priority=10
EOF
    ok "local repo -> $BF_LOCALREPO"
}

s60_netrepo() {
    cat > /etc/yum.repos.d/blackflag.repo <<EOF
# BlackFlag Linux network repositories.
# Disabled until repo.blackflag.com.bd is published - see docs/ARCHITECTURE.md 6.2
[blackflag-os]
name=BlackFlag Linux \$releasever - OS (\$basearch)
baseurl=https://repo.blackflag.com.bd/blackflag/\$releasever/\$basearch/os/
enabled=0
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$BF_KEYFILE

[blackflag-updates]
name=BlackFlag Linux \$releasever - Updates (\$basearch)
baseurl=https://repo.blackflag.com.bd/blackflag/\$releasever/\$basearch/updates/
enabled=0
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$BF_KEYFILE

[blackflag-extras]
name=BlackFlag Linux \$releasever - Extras (\$basearch)
baseurl=https://repo.blackflag.com.bd/blackflag/\$releasever/\$basearch/extras/
enabled=0
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$BF_KEYFILE
EOF
    ok "network repo definitions written (disabled)"
}

# ------------------------------------------------- blackflag-release + base shim
s60_buildpkgs() {
    local top=/root/rpmbuild
    install -d "$top"/{SPECS,SOURCES,BUILD,BUILDROOT,RPMS,SRPMS}
    cp "$PKGDIR"/blackflag-release.spec "$top/SPECS/" || return 1
    cp "$BF_KEYFILE" "$top/SOURCES/" || return 1
    cp "$PKGDIR"/blackflag.repo.in "$top/SOURCES/blackflag.repo" 2>/dev/null || true
    sed -e "s|@RELEASEVER@|$BF_RELEASEVER|g" -e "s|@KEYFILE@|$(basename $BF_KEYFILE)|g" \
        -i "$top/SOURCES/blackflag.repo" 2>/dev/null || true

    # blackflag-base: generated fresh, because its Provides describe THIS machine.
    "$PKGDIR/gen-base-provides.sh" > "$BF_BUILD/base-provides.inc" || return 1
    sed -e "/@PROVIDES@/{r $BF_BUILD/base-provides.inc" -e "d}" \
        "$PKGDIR/blackflag-base.spec.in" > "$top/SPECS/blackflag-base.spec" || return 1

    rpmbuild -bb "$top/SPECS/blackflag-release.spec" >>"$BF_LOGS/seed.log" 2>&1 || return 1
    rpmbuild -bb "$top/SPECS/blackflag-base.spec"    >>"$BF_LOGS/seed.log" 2>&1 || return 1
    ok "built blackflag-release and blackflag-base"
}

s60_install() {
    local top=/root/rpmbuild
    # --justdb for the shim: it must claim nothing on disk, only teach rpm what exists.
    rpm -Uvh --replacefiles --replacepkgs "$top"/RPMS/*/blackflag-release-*.rpm >>"$BF_LOGS/seed.log" 2>&1 || return 1
    rpm -Uvh --justdb --replacepkgs "$top"/RPMS/*/blackflag-base-*.rpm >>"$BF_LOGS/seed.log" 2>&1 || return 1
    ok "rpmdb seeded"
}

s60_publish() {
    local top=/root/rpmbuild
    "$(dirname "$0")/../tools/bf-repo" add "$BF_LOCALREPO" \
        "$top"/RPMS/*/blackflag-release-*.rpm "$top"/RPMS/*/blackflag-base-*.rpm \
        >>"$BF_LOGS/seed.log" 2>&1 || return 1
    ok "bootstrap packages signed and published to $BF_LOCALREPO"
}

: > "$BF_LOGS/seed.log"
s60_macros    || die "macros"
s60_gpgkey    || die "gpg key"
s60_dnfconf   || die "dnf config"
s60_netrepo   || die "network repos"
s60_buildpkgs || die "building release/base packages"
s60_install   || die "installing release/base packages"
s60_localrepo || die "local repo"
s60_publish   || die "publishing bootstrap packages"
msg "stage 60 complete"
rpm -qa
