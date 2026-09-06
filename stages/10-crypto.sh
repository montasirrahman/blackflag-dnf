#!/bin/bash
# Stage 10 - GnuPG stack.  rpm/dnf need gpgme for repo + package signature checking,
# and the gpg binary itself for key management and rpm --addsign.
. "$(dirname "$0")/../lib/common.sh"

std() { local n="$1"; shift
    ./configure --prefix=/usr --disable-static "$@" >>"$BF_LOGS/$n.log" 2>&1 \
    && make -j"$BF_JOBS" >>"$BF_LOGS/$n.log" 2>&1 \
    && make install >>"$BF_LOGS/$n.log" 2>&1; }

b_gpgerror() { std libgpg-error --enable-install-gpg-error-config; }
b_gcrypt()   { std libgcrypt; }
b_assuan()   { std libassuan; }
b_ksba()     { std libksba; }
b_npth()     { std npth; }
b_gnupg()    { std gnupg --localstatedir=/var --sysconfdir=/etc \
                   --enable-gpg-is-gpg2 --disable-ldap --disable-gnutls --disable-doc; }
# gpgme: C++ bindings are what libdnf5 links against; python bindings are handy for tooling.
b_gpgme()    { std gpgme --enable-languages=cpp,python; }

build_pkg libgpg-error 'libgpg-error-*.tar.bz2' "libgpg-error-1.55" b_gpgerror
build_pkg libgcrypt    'libgcrypt-*.tar.bz2'    "libgcrypt-1.11.1"  b_gcrypt
build_pkg libassuan    'libassuan-*.tar.bz2'    "libassuan-3.0.2"   b_assuan
build_pkg libksba      'libksba-*.tar.bz2'      "libksba-1.6.7"     b_ksba
build_pkg npth         'npth-*.tar.bz2'         "npth-1.8"          b_npth
build_pkg gnupg        'gnupg-*.tar.bz2'        "gnupg-2.4.8"       b_gnupg
build_pkg gpgme        'gpgme-*.tar.bz2'        "gpgme-1.24.3"      b_gpgme
msg "stage 10 complete"
