#!/bin/bash
# Stage 30 - the libraries libdnf5 sits on top of.
. "$(dirname "$0")/../lib/common.sh"

cm() { local n="$1"; shift
    cmake -S . -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release "$@" >>"$BF_LOGS/$n.log" 2>&1 \
    && ninja -C build -j"$BF_JOBS" >>"$BF_LOGS/$n.log" 2>&1 \
    && ninja -C build install >>"$BF_LOGS/$n.log" 2>&1; }

ms() { local n="$1"; shift
    meson setup build --prefix=/usr --libdir=lib --buildtype=release "$@" >>"$BF_LOGS/$n.log" 2>&1 \
    && ninja -C build -j"$BF_JOBS" >>"$BF_LOGS/$n.log" 2>&1 \
    && ninja -C build install >>"$BF_LOGS/$n.log" 2>&1; }

b_libyaml() { ./configure --prefix=/usr --disable-static >>"$BF_LOGS/libyaml.log" 2>&1 \
    && make -j"$BF_JOBS" >>"$BF_LOGS/libyaml.log" 2>&1 && make install >>"$BF_LOGS/libyaml.log" 2>&1; }

# glib without gobject-introspection: nothing in the dnf5 chain needs the typelibs.
b_glib() { ms glib -Dintrospection=disabled -Dman-pages=disabled -Dtests=false \
    -Dselinux=disabled -Dsysprof=disabled -Ddtrace=disabled -Dnls=enabled; }

b_jsonc()  { cm json-c -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF -DDISABLE_WERROR=ON; }
b_zchunk() { ms zchunk -Dwith-zstd=enabled; }

# libsolv is the SAT dependency solver.  The rpm backends must be on or dnf cannot
# read the local rpmdb; zchunk + all compressions on so it can read any repodata.
b_libsolv() { cm libsolv \
    -DENABLE_RPMDB=ON -DENABLE_RPMPKG=ON -DENABLE_PUBKEY=ON -DENABLE_RPMDB_BYRPMHEADER=ON \
    -DENABLE_RPMDB_LIBRPM=ON -DENABLE_RPMPKG_LIBRPM=ON -DENABLE_RPMMD=ON -DENABLE_COMPS=ON \
    -DENABLE_APPDATA=ON -DENABLE_COMPLEX_DEPS=ON -DENABLE_LZMA_COMPRESSION=ON \
    -DENABLE_BZIP2_COMPRESSION=ON -DENABLE_ZSTD_COMPRESSION=ON -DENABLE_ZCHUNK_COMPRESSION=ON \
    -DMULTI_SEMANTICS=ON -DSUSE=OFF -DFEDORA=ON -DENABLE_STATIC=OFF -DDISABLE_SHARED=OFF; }

b_librepo() { cm librepo -DENABLE_PYTHON=ON -DWITH_ZCHUNK=ON -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF; }
b_libcomps(){ cd libcomps && cm libcomps -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF -DENABLE_PYTHON=ON; }
b_modulemd(){ ms libmodulemd -Dwith_docs=false -Dwith_manpages=disabled -Dskip_introspection=true \
    -Dwith_py3=false -Dtest_installed_lib=false; }

b_fmt()    { cm fmt -DBUILD_SHARED_LIBS=ON -DFMT_TEST=OFF -DFMT_DOC=OFF; }
b_spdlog() { cm spdlog -DBUILD_SHARED_LIBS=ON -DSPDLOG_FMT_EXTERNAL=ON \
    -DSPDLOG_BUILD_EXAMPLE=OFF -DSPDLOG_BUILD_TESTS=OFF; }
b_toml11() { cm toml11 -Dtoml11_BUILD_TEST=OFF; }

build_pkg libyaml     'yaml-*.tar.gz'         "yaml-0.2.5"           b_libyaml
build_pkg glib        'glib-*.tar.xz'         "glib-2.84.4"          b_glib
build_pkg json-c      'json-c-*.tar.gz'       "json-c-json-c-0.18-20240915" b_jsonc
build_pkg zchunk      'zchunk-*.tar.gz'       "zchunk-1.5.1"         b_zchunk
build_pkg fmt         'fmt-*.tar.gz'          "fmt-11.1.4"           b_fmt
build_pkg spdlog      'spdlog-*.tar.gz'       "spdlog-1.15.1"        b_spdlog
build_pkg toml11      'toml11-*.tar.gz'       "toml11-4.4.0"         b_toml11
build_pkg libsolv     'libsolv-*.tar.gz'      "libsolv-0.7.32"       b_libsolv
build_pkg librepo     'librepo-*.tar.gz'      "librepo-1.20.0"       b_librepo
build_pkg libcomps    'libcomps-*.tar.gz'     "libcomps-0.1.21"      b_libcomps
build_pkg libmodulemd 'libmodulemd-*.tar.gz'  "libmodulemd-libmodulemd-2.15.2" b_modulemd
msg "stage 30 complete"
