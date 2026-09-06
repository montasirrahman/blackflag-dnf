# Building BlackFlag packages

## The three-minute version

```bash
bf-newpkg zlib 1.3.1 https://zlib.net/zlib-1.3.1.tar.gz   # scaffold a spec
cd ~/rpmbuild && curl -LO https://zlib.net/zlib-1.3.1.tar.gz && mv *.tar.gz SOURCES/
rpmbuild -ba SPECS/zlib.spec                              # build
bf-repo add local ~/rpmbuild/RPMS/*/zlib-*.rpm            # sign + publish
dnf5 install zlib                                         # consume
```

## The build tree

`rpmbuild` works out of `~/rpmbuild`, which `bf-newpkg` creates:

```
~/rpmbuild/
├── SPECS/       your .spec files
├── SOURCES/     tarballs and patches, flat (no subdirectories)
├── BUILD/       where %prep unpacks and %build compiles
├── BUILDROOT/   the fake / that %install populates
├── RPMS/        finished binary packages, per-arch
└── SRPMS/       source packages
```

The single most important rule: **`%install` writes into `%{buildroot}`, never
into the real filesystem.** A spec that installs to `/usr` directly will damage
the build host. The `%make_install` macro handles this by passing
`DESTDIR=%{buildroot}`; if a build system does not honour `DESTDIR`, that is the
thing to patch.

## Spec anatomy

```spec
Name:           foo
Version:        1.2.3
Release:        1%{?dist}        # -> 1.bf1
Summary:        One line, no trailing period
License:        GPL-2.0-or-later # SPDX identifier
URL:            https://example.com/foo
Source0:        %{url}/releases/foo-%{version}.tar.xz
Patch0:         foo-1.2.3-fix-build.patch

BuildRequires:  gcc make pkgconfig(zlib)
Requires:       bash              # ONLY what rpm cannot detect itself

%description
A paragraph. Wrapped at 80 columns.

%prep
%autosetup -p1        # unpacks Source0 and applies every PatchN

%build
%configure --disable-static
%make_build           # = make -j$(nproc)

%install
%make_install         # = make install DESTDIR=%{buildroot}
find %{buildroot} -name '*.la' -delete

%check
%make_build check     # runs during rpmbuild -ba; catches broken builds early

%files
%license COPYING
%doc README NEWS
%{_bindir}/foo
%{_libdir}/libfoo.so.*

%package devel
Summary:        Development files for foo
Requires:       %{name}%{?_isa} = %{version}-%{release}
%description devel
Headers and libraries for developing against foo.
%files devel
%{_includedir}/foo.h
%{_libdir}/libfoo.so
%{_libdir}/pkgconfig/foo.pc

%changelog
* Sat Sep 06 2026 You <you@blackflag.com.bd> - 1.2.3-1
- Initial BlackFlag package
```

### Requires you should write, and ones you should not

rpm scans the built binaries and generates `Requires:` for every shared library
they link against, plus `Provides:` for every library they ship. Do not duplicate
that by hand — it goes stale and it can be wrong.

Write `Requires:` only for dependencies rpm cannot see:

- interpreters or tools invoked from shell scripts (`Requires: bash`, `Requires: python3`)
- data or config supplied by another package
- a `-devel` subpackage requiring its base package (`%{name}%{?_isa} = %{version}-%{release}`)
- explicit ordering (`Requires(post):`, `Requires(preun):`)

`%{?_isa}` matters: it appends `(x86_64)` so a 64-bit devel package cannot be
satisfied by a 32-bit base package.

## Useful macros

| Macro | Expands to |
|---|---|
| `%{_bindir}` `%{_sbindir}` | `/usr/bin` `/usr/sbin` |
| `%{_libdir}` | `/usr/lib` |
| `%{_includedir}` | `/usr/include` |
| `%{_datadir}` | `/usr/share` |
| `%{_sysconfdir}` | `/etc` |
| `%{_localstatedir}` | `/var` |
| `%{_unitdir}` | systemd unit directory |
| `%{?dist}` | `.bf1` |
| `%{?_isa}` | `(x86_64)` |

Inspect any of them: `rpm --eval '%{_libdir}'`

## Verifying before you publish

```bash
rpm -qpi  foo-1.2.3-1.bf1.x86_64.rpm    # metadata
rpm -qpl  foo-1.2.3-1.bf1.x86_64.rpm    # file list
rpm -qp --requires foo-*.rpm            # generated dependencies
rpm -qp --provides foo-*.rpm            # generated provides
rpmlint  foo-*.rpm                      # style/correctness (when available)
rpm -Uvh --test foo-*.rpm               # dry-run install
```

Check the file list before every first publish. The two failure modes that bite
hardest are files silently omitted from `%files` (rpmbuild errors on unpackaged
files, which is the good case) and a package accidentally owning a directory
another package also owns.

## Signing

`bf-repo add` signs automatically. To sign by hand:

```bash
rpmsign --addsign foo-1.2.3-1.bf1.x86_64.rpm
rpm -qp --qf '%{SIGPGP:pgpsig}\n' foo-*.rpm    # confirm
rpmkeys --checksig foo-*.rpm                   # verify
```

## A warning about the current build environment

Packages are built directly on the host, not in a clean chroot. That means
`BuildRequires:` are not actually enforced — a build can quietly succeed because
some header happens to be installed on the build machine, and then fail for
everyone else. Until an isolated build root exists (roadmap item), treat
`BuildRequires:` as something to get right by inspection rather than something
the tooling will catch.
