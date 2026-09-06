#!/bin/bash
# Stage 50 - repository-side tooling: createrepo_c builds the repodata that dnf consumes.
. "$(dirname "$0")/../lib/common.sh"

b_createrepo() {
    local L="$BF_LOGS/createrepo_c.log"
    cmake -S . -B build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
        -DWITH_ZCHUNK=ON -DWITH_LIBMODULEMD=ON -DENABLE_DRPM=OFF \
        -DENABLE_PYTHON=ON -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF \
        >>"$L" 2>&1 || return 1
    ninja -C build -j"$BF_JOBS" >>"$L" 2>&1 || return 1
    ninja -C build install       >>"$L" 2>&1 || return 1
}

build_pkg createrepo_c 'createrepo_c-*.tar.gz' "createrepo_c-1.2.1" b_createrepo
msg "stage 50 complete"
