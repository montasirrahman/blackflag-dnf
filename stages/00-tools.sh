#!/bin/bash
# Stage 00 - build tools missing from the LFS base that the rest of the chain needs.
. "$(dirname "$0")/../lib/common.sh"

b_curl() { ./configure --prefix=/usr --disable-static --with-openssl --without-libidn2 \
    --without-libpsl --enable-threaded-resolver --with-ca-path=/etc/ssl/certs >>"$BF_LOGS/curl.log" 2>&1 \
    && make -j"$BF_JOBS" >>"$BF_LOGS/curl.log" 2>&1 && make install >>"$BF_LOGS/curl.log" 2>&1; }

b_git() { ./configure --prefix=/usr --with-gitconfig=/etc/gitconfig --with-curl --with-expat \
    --with-openssl >>"$BF_LOGS/git.log" 2>&1 \
    && make -j"$BF_JOBS" NO_TCLTK=1 >>"$BF_LOGS/git.log" 2>&1 \
    && make NO_TCLTK=1 install >>"$BF_LOGS/git.log" 2>&1; }

b_pcre2() { ./configure --prefix=/usr --enable-unicode --enable-jit --enable-pcre2-16 \
    --enable-pcre2-32 --enable-pcre2grep-libz --enable-pcre2grep-libbz2 --disable-static \
    >>"$BF_LOGS/pcre2.log" 2>&1 && make -j"$BF_JOBS" >>"$BF_LOGS/pcre2.log" 2>&1 \
    && make install >>"$BF_LOGS/pcre2.log" 2>&1; }

# NOTE: patches/cmake-3.31.6-curl-8.15-netrc.patch is applied automatically by
# build_pkg; without it CMake will not compile against the system curl 8.15.
b_cmake() { ./bootstrap --prefix=/usr --system-curl --system-zlib --system-bzip2 \
    --system-liblzma --system-expat --no-system-libarchive --parallel="$BF_JOBS" --generator=Ninja \
    >>"$BF_LOGS/cmake.log" 2>&1 && ninja -j"$BF_JOBS" >>"$BF_LOGS/cmake.log" 2>&1 \
    && ninja install >>"$BF_LOGS/cmake.log" 2>&1; }

b_libxml2() { ./configure --prefix=/usr --sysconfdir=/etc --disable-static --with-history \
    --with-icu --without-python >>"$BF_LOGS/libxml2.log" 2>&1 \
    && make -j"$BF_JOBS" >>"$BF_LOGS/libxml2.log" 2>&1 && make install >>"$BF_LOGS/libxml2.log" 2>&1; }

b_swig() { ./configure --prefix=/usr --without-maximum-compile-warnings \
    >>"$BF_LOGS/swig.log" 2>&1 && make -j"$BF_JOBS" >>"$BF_LOGS/swig.log" 2>&1 \
    && make install >>"$BF_LOGS/swig.log" 2>&1; }

build_pkg curl    'curl-*.tar.xz'    "curl-8.15.0"    b_curl
build_pkg git     'git-*.tar.xz'     "git-2.51.0"     b_git
build_pkg pcre2   'pcre2-*.tar.bz2'  "pcre2-10.45"    b_pcre2
build_pkg cmake   'cmake-*.tar.gz'   "cmake-3.31.6"   b_cmake
build_pkg libxml2 'libxml2-*.tar.xz' "libxml2-2.13.8" b_libxml2
build_pkg swig    'swig-*.tar.gz'    "swig-4.3.1"     b_swig
msg "stage 00 complete"
