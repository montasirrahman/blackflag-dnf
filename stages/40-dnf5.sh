#!/bin/bash
# Stage 40 - dnf5 / libdnf5 itself.
. "$(dirname "$0")/../lib/common.sh"

b_dnf5() {
    local L="$BF_LOGS/dnf5.log"
    # The dbus daemon (dnf5daemon) needs sdbus-c++, which is not part of the base system;
    # it is optional and off here.  Man pages need pandoc, also off.
    cmake -S . -B build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_SYSCONFDIR=/etc \
        -DCMAKE_INSTALL_LOCALSTATEDIR=/var \
        -DCMAKE_BUILD_TYPE=Release \
        -DPROJECT_VERSION_PRERELEASE="" \
        -DWITH_DNF5DAEMON_CLIENT=OFF \
        -DWITH_DNF5DAEMON_SERVER=OFF \
        -DWITH_TESTS=OFF \
        -DWITH_PERFORMANCE_TESTS=OFF \
        -DWITH_MAN=OFF \
        -DWITH_HTML=OFF \
        -DWITH_COMPS=ON \
        -DWITH_MODULEMD=ON \
        -DWITH_ZCHUNK=ON \
        -DWITH_SYSTEMD=ON \
        -DWITH_PLUGIN_ACTIONS=ON \
        -DWITH_PLUGIN_RHSM=OFF \
        -DWITH_PYTHON_PLUGINS_LOADER=ON \
        -DWITH_PYTHON3=ON \
        -DWITH_PERL5=OFF \
        -DWITH_RUBY=OFF \
        -DWITH_GO=OFF \
        -DWITH_JSON=ON \
        >>"$L" 2>&1 || return 1
    ninja -C build -j"$BF_JOBS" >>"$L" 2>&1 || return 1
    ninja -C build install       >>"$L" 2>&1 || return 1
    install -d /etc/dnf/{vars,protected.d,plugins,repos.d,libdnf5-plugins} \
               /var/cache/libdnf5 /var/lib/dnf /var/log
    ln -sfn dnf5 /usr/bin/dnf
}

build_pkg dnf5 'dnf5-*.tar.gz' "dnf5-5.2.13.0" b_dnf5
msg "stage 40 complete"
