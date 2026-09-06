# blackflag-dnf

Bootstrap of the **RPM + DNF5** package-management stack for
[BlackFlag Linux](https://blackflag.com.bd) — an LFS 12.4-systemd derivative that
ships with no package manager capable of owning `/`.

These scripts take a bare BlackFlag/LFS box and leave it with a working
`rpm`, `rpmbuild`, `dnf5` and `createrepo_c`, a seeded RPM database, a signing
key, and a usable local repository.

> Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) first. It explains why dnf5
> rather than dnf4, how the repositories are laid out, and — most importantly —
> how an RPM database gets seeded on a system whose userland was built before RPM
> existed.

## Usage

```bash
./fetch-sources.sh          # download every upstream tarball into ../src
sudo ./build-all.sh         # run all stages
sudo ./build-all.sh 30 40   # or just some stages
```

Builds are resumable — each package stamps `work/stamps/` and is skipped on a
re-run. Delete a stamp to force a rebuild.

## Stages

| Stage | Builds |
|---|---|
| `00-tools` | curl, git, pcre2, cmake, libxml2, swig |
| `10-crypto` | libgpg-error, libgcrypt, libassuan, libksba, npth, gnupg, gpgme |
| `20-rpm` | lua (shared), **rpm 4.20.1**, `rpmdb --initdb` |
| `30-dnflibs` | libyaml, glib2, json-c, zchunk, fmt, spdlog, toml11, libsolv, librepo, libcomps, libmodulemd |
| `40-dnf5` | **libdnf5 + dnf5** |
| `50-repotools` | createrepo_c |
| `60-seed` | rpm macros, GPG key, `blackflag-release`, `blackflag-base`, repo config |
| `70-selfhost` | repackage the bootstrap stack as RPMs so dnf can upgrade dnf |

## Tools installed

| Tool | Purpose |
|---|---|
| `bf-repo` | create / add to / sign / verify / prune a BlackFlag repository |
| `bf-newpkg` | scaffold a spec file that follows BlackFlag conventions |
| `hud2rpm` | convert legacy `.hud` packages into RPMs |
| `hud-compat` | translate `hud` command lines into `dnf5` ones |
| `bf-selftest` | end-to-end check: build → sign → publish → install → remove |
| `bf-lfs-audit` | how much of the filesystem RPM actually owns |
| `bf-repack` | turn an already-built tree into an RPM without recompiling |

## Layout

```
build-all.sh          driver
fetch-sources.sh      downloader
sources.list          upstream manifest (stage|name|version|url)
lib/common.sh         shared build helpers
stages/               one script per stage
packaging/            blackflag-release + blackflag-base specs, provides generator
tools/                bf-repo, bf-newpkg, hud2rpm
patches/              upstream fixes applied automatically at unpack time
docs/ARCHITECTURE.md  the design document, status and known limitations
docs/OPERATIONS.md    day-to-day: add a package, maintain a repo, rotate keys
docs/PACKAGING.md     how to build a BlackFlag package
```
