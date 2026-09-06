#!/bin/bash
# Stage 20 - Lua (an rpm build requirement) and rpm itself.
# rpm 4.20 builds with CMake, so stage 00 must have installed cmake first.
. "$(dirname "$0")/../lib/common.sh"

LUA_VER=5.4.8
LUA_MAJ=5.4

b_lua() {
    local L="$BF_LOGS/lua.log"
    # Upstream lua ships no shared-library target; build PIC objects and link one by hand.
    make linux MYCFLAGS="-fPIC" -j"$BF_JOBS" >>"$L" 2>&1 || return 1
    ( cd src && gcc -shared -Wl,-soname,liblua.so.$LUA_MAJ \
        -o liblua.so.$LUA_VER $(ls *.o | grep -Ev '^(lua|luac)\.o$') -lm -ldl ) >>"$L" 2>&1 || return 1
    install -Dm755 src/lua      /usr/bin/lua      || return 1
    install -Dm755 src/luac     /usr/bin/luac     || return 1
    install -Dm644 src/liblua.a /usr/lib/liblua.a || return 1
    install -Dm755 src/liblua.so.$LUA_VER /usr/lib/liblua.so.$LUA_VER || return 1
    ln -sfn liblua.so.$LUA_VER /usr/lib/liblua.so.$LUA_MAJ
    ln -sfn liblua.so.$LUA_MAJ /usr/lib/liblua.so
    install -d /usr/include
    install -m644 src/lua.h src/luaconf.h src/lualib.h src/lauxlib.h src/lua.hpp /usr/include/ || return 1
    # rpm's cmake probe finds Lua through pkg-config
    cat > /usr/lib/pkgconfig/lua.pc <<PC
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
INSTALL_LMOD=\${prefix}/share/lua/$LUA_MAJ
INSTALL_CMOD=\${prefix}/lib/lua/$LUA_MAJ

Name: Lua
Description: An extensible extension language
Version: $LUA_VER
Libs: -L\${libdir} -llua -lm -ldl
Cflags: -I\${includedir}
PC
    ln -sfn lua.pc /usr/lib/pkgconfig/lua$LUA_MAJ.pc
    ln -sfn lua.pc /usr/lib/pkgconfig/lua-$LUA_MAJ.pc
    install -d /usr/share/lua/$LUA_MAJ /usr/lib/lua/$LUA_MAJ
}

b_rpm() {
    local L="$BF_LOGS/rpm.log"
    # rpmdb lives at /var/lib/rpm with the sqlite backend (the rpm >= 4.16 default).
    cmake -S . -B build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_SYSCONFDIR=/etc \
        -DCMAKE_INSTALL_LOCALSTATEDIR=/var \
        -DRPM_VENDOR=blackflag \
        -DENABLE_PYTHON=ON \
        -DENABLE_PLUGINS=ON \
        -DENABLE_OPENMP=OFF \
        -DENABLE_TESTSUITE=OFF \
        -DENABLE_NLS=ON \
        -DWITH_CRYPTO=openssl \
        -DWITH_INTERNAL_OPENPGP=ON \
        -DWITH_SEQUOIA=OFF \
        -DWITH_ACL=ON \
        -DWITH_CAP=ON \
        -DWITH_AUDIT=OFF \
        -DWITH_SELINUX=OFF \
        -DWITH_IMAEVM=OFF \
        -DWITH_FSVERITY=OFF \
        -DWITH_FAPOLICYD=OFF \
        -DWITH_DBUS=OFF \
        -DWITH_READLINE=ON \
        -DWITH_ARCHIVE=ON \
        -DWITH_DOXYGEN=OFF \
        >>"$L" 2>&1 || return 1
    ninja -C build -j"$BF_JOBS" >>"$L" 2>&1 || return 1
    ninja -C build install       >>"$L" 2>&1 || return 1
    install -d /var/lib/rpm /var/cache/rpm /var/lib/rpm/backup
    rpmdb --initdb >>"$L" 2>&1 || return 1
}

build_pkg lua 'lua-*.tar.gz'    "lua-$LUA_VER" b_lua
build_pkg rpm 'rpm-*.tar.bz2'   "rpm-4.20.1"   b_rpm
msg "stage 20 complete"
