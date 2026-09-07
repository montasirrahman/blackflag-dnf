# BlackFlag Linux — DNF Package Management Architecture

Target system: **BlackFlag Linux 1.0.0 "Fajr"** — an LFS 12.4-systemd derivative,
x86_64, glibc 2.42, GCC 15.2.0, Python 3.13.7, Linux 6.16.1.

---

## 1. Where the system stands today

The base install was surveyed before any work began. Findings:

| Area | State |
|---|---|
| Base | LFS 12.4-systemd, complete toolchain (gcc, autotools, meson, ninja, perl, bison, flex, pkgconf, gettext) |
| Existing package manager | `hud` v1.0 — a 47 KB bash script |
| `hud` metadata | flat pipe-delimited `packages.list`, sqlite3 local DB at `/var/lib/hud/db/local.db` |
| `hud` payload | `.hud` files = plain `tar.gz`, extracted to `/`, everything prefixed into `/opt/hud` |
| `hud` state | zero packages installed; `/opt/hud/{bin,sbin,lib}` empty; repo `hud1.naim.com.bd` unreachable |
| RPM stack | **absent** — no rpm, rpmbuild, dnf, yum, createrepo |
| Missing build tools | curl, git, cmake, swig, libxml2 |
| Missing libraries | glib2, pcre2, libyaml, json-c, libxml2, the whole GnuPG stack, libsolv, librepo, libcomps, libmodulemd, zchunk, fmt, spdlog, toml11 |
| Present and reusable | popt, libarchive, libelf, libmagic, libcap, libacl, sqlite3, openssl 3.5.2, expat, libffi, zlib/xz/bz2/zstd/lz4, icu, readline, ncurses, systemd, dbus |
| Present but incomplete | elfutils — LFS installs `libelf` only, and rpm hard-requires `libdw` |
| Resources | 926 GB free, 2 cores, 3.8 GB RAM + 4 GB swap, outbound HTTPS working |

### What `hud` is and is not

`hud` is a *side-loading* manager. Because everything lands in `/opt/hud`, it can never
own `/usr` — it is structurally incapable of managing the base OS. Its dependency
"resolution" is a recursive walk, not a solver: it cannot handle conflicts, obsoletes,
alternate providers, versioned boolean deps, or multi-package upgrade transactions. There
is no signature verification, no transaction rollback, and no file-level conflict
detection between packages.

That is fine for an add-on tray. It is not a distribution package manager. DNF is the
replacement, and it takes over `/`.

---

## 2. Design decisions

### 2.1 dnf5, not dnf4

| | dnf4 | **dnf5 (chosen)** |
|---|---|---|
| Language | Python on top of C++ `libdnf` | one C++20 codebase, `libdnf5` |
| Bindings | SWIG-heavy (`hawkey`, `libdnf`, `dnf`) | optional SWIG bindings, core needs none |
| Upstream status | maintenance only, superseded in Fedora 41+ | current, actively developed |
| Bootstrap cost | rpm-python + hawkey + libdnf + dnf + plugins | rpm + libdnf5 + dnf5 |
| Runtime | needs a working Python for *every* transaction | a static-ish native binary |

The last row matters most for a from-scratch distro: with dnf5, a broken Python does not
brick package management. On this system Python is already missing its `_sqlite3` module,
which is exactly the class of problem that takes dnf4 down.

**Decision: dnf5 (5.2.x), with `dnf` provided as a symlink to `dnf5`.**

### 2.2 DNF owns `/`, not `/opt`

`hud` installs to `/opt/hud`. DNF is installed into `/usr` and its database lives at
`/var/lib/rpm`. This is deliberate and non-negotiable: a distribution package manager must
be able to replace glibc, systemd, and the kernel. Prefix-isolating it would reproduce
`hud`'s central limitation.

`hud` is **not removed**. It keeps working against `/opt/hud` during the transition
(see §7).

### 2.3 Layout: `%_libdir` is `/usr/lib`, not `/usr/lib64`

BlackFlag inherits LFS's layout. `/usr/lib64` does not exist, and `/lib64` holds
only the `ld-linux-x86-64.so.2` symlinks that the ELF interpreter path requires.
Every real library lives in `/usr/lib`.

rpm's `x86_64-linux` platform macros set `%_lib` to `lib64`. Left alone, every
library package would install into a directory that is not on the linker path,
and nothing would say so at build time — the failure surfaces later, at runtime,
in whatever tried to link against it. `macros.blackflag` therefore pins:

```
%_lib      lib
%_libdir   %{_exec_prefix}/%{_lib}
```

`bf-selftest` asserts this, because it is the kind of setting that silently
un-sets itself when someone regenerates macros from an upstream template.

### 2.4 Optional components turned off, and why

| Off | Reason |
|---|---|
| `dnf5daemon` (client + server) | the D-Bus API is only needed by GUI front ends (PackageKit, Cockpit). Can be added later without rebuilding anything else. |
| `WITH_PLUGIN_APPSTREAM` | requires `libappstream`; only feeds GUI software centres, which BlackFlag does not ship |
| `ccmake` | ncurses' `curses.h` redefines `bool`, breaking `std::integral_constant` matching under GCC 15. Nothing here drives cmake interactively. |
| librepo `ENABLE_SELINUX` | no SELinux policy is enforced, and rpm was built `WITH_SELINUX=OFF` |
| man/html docs | require `pandoc` (a Haskell toolchain) |
| `WITH_PLUGIN_RHSM` | Red Hat subscription-manager integration; meaningless here |
| rpm `WITH_SEQUOIA` | pulls in a Rust toolchain; rpm's internal OpenPGP parser + OpenSSL covers signing/verification |
| rpm SELinux / audit / IMA / fsverity | not enabled in the BlackFlag kernel policy today |
| gobject-introspection in glib | nothing in the chain consumes typelibs |

---

## 3. The bootstrap chain

Nothing can be installed *by* dnf until dnf exists, so the entire stack is built from
source, in dependency order, by the stage scripts in `stages/`. Each package writes a
stamp into `work/stamps/`, so a re-run resumes rather than restarts.

```
stage 00  tools      curl → git → pcre2 → cmake → libxml2 → swig
stage 10  crypto     libgpg-error → libgcrypt → libassuan → libksba → npth
                     → gnupg → gpgme(+C++,python)
stage 20  rpm        lua(shared) → rpm 4.20.1 → rpmdb --initdb
stage 30  dnf libs   libyaml   glib2   json-c   zchunk   fmt → spdlog   toml11
                     libsolv(rpm+zchunk backends) → librepo → libcomps → libmodulemd
stage 40  dnf5       libdnf5 + dnf5 + python3 bindings
stage 50  repo tools createrepo_c
stage 60  seeding    blackflag-release, rpm macros, GPG key, rpmdb seed
stage 70  self-host  repackage the whole bootstrap stack as RPMs
```

Stage 70 deserves a note. Everything before it is installed into `/usr` by plain
`make install`, because there is no package manager yet to do it properly. The
side effect is that the package manager becomes the one thing on the system that
dnf cannot upgrade and `rpm -V` cannot attest to. Stage 70 re-runs each install
step with `DESTDIR` pointed at a buildroot and packages the result — no
recompilation, since the trees are still built — so rpm, dnf5, libsolv and the
rest become ordinary RPM content like anything else.

Why each of the stage-30 libraries is required:

- **libsolv** — the SAT solver. Every `dnf install` is compiled into a boolean
  satisfiability problem and solved here. The `RPMDB`/`RPMPKG` backends are what let it
  read `/var/lib/rpm` directly.
- **librepo** — repository fetching: metadata download, mirror handling, checksum and
  GPG verification, delta/zchunk support.
- **libcomps** — parses `comps.xml`, i.e. package *groups* and *environments*
  (`dnf group install "Development Tools"`).
- **libmodulemd** — parses module metadata streams. Not used by BlackFlag yet, but
  compiling it in now avoids an ABI-breaking rebuild later.
- **zchunk** — chunked compression so metadata updates transfer deltas, not whole files.
  Turns a 20 MB `dnf update` metadata refresh into a few hundred KB.
- **fmt / spdlog / json-c / toml11** — formatting, logging, JSON output (`--json`), and
  config parsing inside libdnf5.

---

## 4. On-disk layout after bootstrap

```
/usr/bin/rpm, rpmdb, rpmkeys, rpmsign, rpmbuild, rpmspec
/usr/bin/dnf5                      dnf → dnf5
/usr/bin/createrepo_c, modifyrepo_c, mergerepo_c
/usr/lib/librpm*.so librpmbuild librpmsign
/usr/lib/libdnf5.so libdnf5-cli.so libsolv.so librepo.so libcomps.so libmodulemd.so
/usr/lib/rpm/                      rpm macros, platform files, helper scripts
  ├── macros                       system macros
  └── macros.d/                    drop-ins  (blackflag macros land here)
/usr/lib/python3.13/site-packages/libdnf5/   python bindings

/etc/dnf/dnf.conf                  main config
/etc/dnf/vars/                     $releasever, $basearch, custom vars
/etc/dnf/protected.d/              packages dnf refuses to remove
/etc/yum.repos.d/                  repo definitions   (/etc/dnf/repos.d symlinked here)
/etc/rpm/macros.*                  per-host macro overrides
/etc/pki/rpm-gpg/                  trusted repo signing keys

/var/lib/rpm/rpmdb.sqlite          the RPM database (sqlite backend)
/var/lib/dnf/                      dnf history / transaction DB
/var/cache/libdnf5/                downloaded metadata + packages
/var/log/dnf5.log                  transaction log
```

---

## 5. The empty-rpmdb problem

This is the one genuinely hard part of retrofitting RPM onto an existing LFS system, and
it is worth being explicit about.

After `rpmdb --initdb`, RPM believes **nothing is installed** — but the machine has a full
LFS userland. So `dnf install anything` tries to drag in glibc, bash, coreutils… and then
fails, because those RPMs do not exist yet. Conversely, if you did build them, RPM would
happily overwrite the running libc with an unrelated build.

Three strategies exist. BlackFlag uses (A) now and migrates to (C):

**(A) Base-provides shim — implemented in stage 60.**
A single `blackflag-base` package is generated whose `Provides:` list is derived
mechanically from the live system: every DSO soname found under `/usr/lib` (in RPM's
`libfoo.so.N()(64bit)` form), every pkg-config module, and the LFS package names. It owns
no files. It is installed with `rpm -i --justdb`, so it changes nothing on disk but makes
the rpmdb an honest description of what is present.

*Trade-off, stated plainly:* dependency resolution becomes correct, but file-level
ownership does not — `rpm -qf /usr/bin/bash` still answers "not owned". Upgrades of base
components must go through (C).

**(B) Full LFS rebuild as RPMs.**
Correct but expensive: every LFS package rebuilt under `rpmbuild` with a spec file, ~90
packages. This is the real end state.

**(C) Incremental capture — the migration path.**
Rebuild base packages as RPMs *one at a time*, in LFS build order, each installed with
`rpm -Uvh --force --replacefiles` to take ownership of files the shim did not claim.
Every package moved this way is dropped from `blackflag-base`'s Provides. When the list
empties, `blackflag-base` is retired and the system is 100% RPM-owned. Specs for this live
in the `blackflag-specs` repo, one directory per package, ordered by an `lfs-order` field.

---

## 6. Repository architecture

### 6.1 What an RPM repository actually is

A directory of `.rpm` files plus a `repodata/` directory generated by `createrepo_c`:

```
<repo-root>/
├── Packages/                or a flat layout, or letter-bucketed a/ b/ c/ …
│   └── foo-1.0-1.bf1.x86_64.rpm
└── repodata/
    ├── repomd.xml           index of the metadata files below, + their checksums
    ├── repomd.xml.asc       detached signature over repomd.xml   ← the trust root
    ├── *-primary.xml.zst    name/version/deps/provides/requires for every package
    ├── *-filelists.xml.zst  every file in every package (for `dnf provides /path`)
    ├── *-other.xml.zst      changelogs
    └── *-comps.xml          package groups (optional)
```

Trust chain: the repo's GPG key signs `repomd.xml`; `repomd.xml` carries checksums of the
metadata files; the metadata carries checksums of the RPMs; and each RPM is *itself*
signed. Verifying the signature on `repomd.xml` therefore transitively verifies everything
— which is why **`repo_gpgcheck=1` matters as much as `gpgcheck=1`**.

### 6.2 The three repository kinds BlackFlag will run

**1. Local repository** — `file:///srv/blackflag/repo/local`
No server, no network. Point a `.repo` file at a directory, run `createrepo_c` after
dropping RPMs in. This is the developer loop and the offline-install story.

**2. Self-hosted network repository** — `https://repo.blackflag.com.bd/`
The production layout, served by any static web server:

```
/blackflag/
└── 1.0/                        $releasever
    ├── x86_64/                 $basearch
    │   ├── os/                 frozen release contents
    │   ├── updates/            errata after release
    │   ├── extras/             community / non-core
    │   └── debug/  source/
    └── ...
```
`.repo` files use `$releasever` and `$basearch` so a single definition survives version
bumps. Mirrors are handled with `metalink=` or a `mirrorlist=` URL, never by hardcoding
one host.

**3. GitHub-backed repository** — for bootstrap and CI.
GitHub Releases hosts the RPMs (no size ceiling that matters here), GitHub Pages hosts
`repodata/`. This gives a zero-cost, always-up repo for `blackflag-release` and the
bootstrap RPMs, so a fresh machine can `rpm -i` one URL and then use dnf normally.

### 6.3 Naming and versioning

```
name-version-release.dist.arch.rpm
zlib-1.3.1-2.bf1.x86_64.rpm
     │      │  │   └── arch: x86_64 | noarch | src
     │      │  └────── %{dist} = .bf1   (BlackFlag 1.x)
     │      └───────── release: bumps on every rebuild of the same upstream version
     └──────────────── upstream version
```
`%dist` is set in `/usr/lib/rpm/macros.d/macros.blackflag` so every rebuild is tagged
automatically. Epochs are reserved for the case where upstream versioning goes backwards.

### 6.4 Signing

A dedicated `BlackFlag Linux Package Signing Key <security@blackflag.com.bd>` (RSA 4096)
is generated in stage 60. The private key never belongs on a build host in production —
the intended end state is a detached signing box or a hardware token. Packages are signed
with `rpmsign --addsign`, repos with `gpg --detach-sign --armor repodata/repomd.xml`, and
the public key ships in the `blackflag-release` RPM at `/etc/pki/rpm-gpg/`.

---

## 7. Coexistence and migration from `hud`

`hud` is left installed and functional. The two managers do not collide because they own
disjoint trees (`/opt/hud` vs `/usr`) and disjoint databases.

The migration is one-directional and gradual:

1. **Now** — dnf5 manages everything new. `hud` keeps serving whatever is already in
   `/opt/hud` (currently: nothing).
2. **Next** — `hud2rpm`, a converter that reads a `.hud` tarball plus its
   `packages.list` row and emits a spec + RPM, so any existing hud package can be
   republished into the DNF repo without a manual rewrite.
3. **Then** — the base system is converted per §5(C).
4. **Finally** — `hud` becomes a thin compatibility shim: `hud install X` → `dnf5 install X`,
   keeping muscle memory and any existing scripts working.

---

## 8. Repositories to be maintained on GitHub

| Repo | Contents |
|---|---|
| `blackflag-dnf` | this bootstrap: stage scripts, source manifest, macros, `blackflag-release`, docs. Reproduces the whole stack on a bare LFS box. |
| `blackflag-specs` | one directory per package: `.spec`, patches, sources manifest. The distribution's actual content. |
| `blackflag-repo` | repo publishing tooling: sign, `createrepo_c`, sync to the web root, prune old builds; plus the GitHub Pages bootstrap repo. |

---

## 9. Status

Built and working on `blackflag` as of 2026-09-06:

```
rpm 4.19.1.1     dnf5 5.2.13.0     createrepo_c 1.2.1
50 packages installed, all signed   (32 bootstrap + 18 converted base)
bf-selftest: 53 passed, 0 failed
filesystem coverage: 12% RPM-owned
```

The full round trip is verified: `rpmbuild` -> `rpmsign` -> `createrepo_c` ->
`dnf5 install` with `gpgcheck=1` **and** `repo_gpgcheck=1` -> `rpm -qf` reports
correct ownership -> `dnf5 remove`.

The package manager owns itself: `rpm -qf $(command -v dnf5)` answers
`dnf5-5.2.13.0-1.bf1.x86_64`.

## 10. Roadmap

- [x] Survey the base, decide dnf5 vs dnf4
- [x] Full bootstrap chain, stages 00-70
- [x] Tooling: `bf-repo`, `bf-newpkg`, `bf-selftest`, `bf-lfs-audit`, `bf-repack`, `hud2rpm`, `hud-compat`
- [x] `rpmbuild` verified end to end
- [x] Signing key, macros, `blackflag-release`, rpmdb shim
- [x] Working `dnf5 install` from a signed local repo
- [x] Bootstrap stack repackaged as RPMs and self-owned
- [ ] Publish the bootstrap repo to GitHub Pages (workflow written, Pages not yet enabled)
- [ ] Stand up `repo.blackflag.com.bd`
- [x] Tier 1 of the base converted: 18 leaf libraries and tools, zero ABI regressions
- [ ] Tiers 2 and 3 of the base - coverage 12% -> 100%, then retire `blackflag-base`
- [ ] Build-host isolation (a `mock` equivalent) so `BuildRequires` is actually enforced
- [ ] Move the production signing key off the build host
- [ ] `dnf5daemon` for PackageKit/GUI integration (sdbus-c++ is already built)
- [ ] Migrate to rpm 4.20+/sequoia once BlackFlag has a Rust toolchain (S11)
- [ ] `hud2rpm` conversion of existing hud packages; retire hud to the shim
- [ ] debuginfo subpackages, delta RPMs, comps groups

## 10b. Converting the base: what a rebuild gets wrong

Nobody recorded the configure flags LFS used, so every converted package is a
guess until proven otherwise. Guessing wrong produces a library that compiles,
packages, and installs cleanly, then breaks its consumers at run time. All four
of these were real on this system, and all four were caught by `bf-abi-check`
comparing the rebuild against the installed copy:

| Package | What drifted |
|---|---|
| `readline` | linked no `libncursesw`, so no termcap symbol resolved. `--with-curses` governs the *static* link; the shared one needs `make SHLIB_LIBS=-lncursesw` |
| `sqlite` | dropped seven public API symbols; `SQLITE_ENABLE_COLUMN_METADATA` was not defined |
| `libarchive` | switched expat → libxml2 for xar. libxml2 did not exist when LFS built it, but this bootstrap installed it since |
| `gmp` | tunes to the build CPU; a host-tuned rebuild omits `__gmpn_clz_tab`, which the installed generic build exports |

Two further traps are about *what* you are converting, not how:

- `grep` on BlackFlag is **ugrep 7.8.4** and `find` is **bfs 4.1.1**. Converting
  the GNU originals would silently revert two deliberate distribution choices.
  Stage 80 now probes the installed version and refuses when it disagrees with
  the manifest.
- GCC 15 defaults to C23, where `void g(){}` declares a function taking *no*
  arguments rather than an unspecified list. gmp's own compiler probe calls such
  a function with six arguments, fails to compile, and concludes there is no
  working compiler. `-std=gnu17` restores the old semantics.

## 11. Known limitations, stated plainly

**rpm is 4.19, not 4.20+.** rpm 4.20 removed the in-tree OpenPGP parser; its only
remaining backend is `rpm-sequoia`, which needs a Rust toolchain and pulls roughly
a hundred crates from crates.io at build time. 4.19.1.1 is the last release
shipping `rpmpgp_internal.c`, which upstream marks deprecated. This is a dead end
with a known expiry date, not a permanent choice.

*Watch the failure mode:* with `WITH_SEQUOIA=OFF` and no legacy backend available,
rpm links `rpmpgp_dummy.c` and **builds successfully with no OpenPGP support at
all** - no key import, no verification, no signing, and no error until you try it.
Stage 20 and `bf-selftest` both assert that `librpmio` exports `pgpParsePkts`, so
this cannot regress quietly.

**Packages build on the host, not in a clean root.** `BuildRequires:` is therefore
documentation, not enforcement: a build can succeed because a header happens to be
present on this machine, and fail everywhere else.

**File ownership is 12%.** Dependency resolution is correct, but
`rpm -qf /usr/bin/bash` still answers "not owned". Section 5 describes the fix.

**The signing key sits on the build host, unprotected.** Correct for
bootstrapping, wrong for production. It should move to a dedicated signer or a
hardware token before anything is published publicly.

**`git` ships without `git-svn`, `git-cvsserver`, `git-instaweb`, `git-p4`.** They
need perl modules and a `/usr/bin/python` that BlackFlag does not have. Upstream
distributions subpackage these; BlackFlag currently drops them.
