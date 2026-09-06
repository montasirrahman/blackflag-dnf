# Day-to-day operation

Everything below assumes the bootstrap has run. Verify with `bf-selftest`.

## Add a package to BlackFlag

```bash
bf-newpkg foo 1.2.3 https://example.com/foo-1.2.3.tar.xz
cd ~/rpmbuild && curl -LO https://example.com/foo-1.2.3.tar.xz && mv *.tar.xz SOURCES/
# edit SPECS/foo.spec: Summary, License, BuildRequires, %files
rpmbuild -ba SPECS/foo.spec
bf-repo add local ~/rpmbuild/RPMS/*/foo-1.2.3-1.bf1*.rpm
dnf5 install foo
```

`bf-repo add` signs, copies, regenerates `repodata/`, and re-signs `repomd.xml`.

## Package something already built outside rpmbuild

```bash
bf-repack foo 1.2.3 /path/to/built/tree make install
BF_REPACK_EXCLUDE="/usr/share/doc/*" bf-repack foo 1.2.3 /path/to/tree ninja -C build install
```

Re-runs the install step with `DESTDIR` and packages the result — no recompile.

## Repository maintenance

```bash
bf-repo list   local            # contents + signature status
bf-repo verify local            # every package signature + the repomd signature
bf-repo clean  local 2          # keep the 2 newest builds per package name
bf-repo update local            # regenerate metadata after manual changes
bf-repo-sync   /srv/blackflag/repo/local  user@host:/srv/www/blackflag/1.0/x86_64/os
```

`bf-repo-sync` copies packages **before** metadata, so clients never see a
`repomd.xml` referencing files that have not landed yet.

## Watch the migration

```bash
bf-lfs-audit                    # % of the filesystem RPM owns
bf-lfs-audit --dirs             # where the unowned files are
bf-lfs-audit --provides         # what blackflag-base is still standing in for
```

When a base package is rebuilt as a real RPM, install it with
`rpm -Uvh --replacefiles` to take ownership, then regenerate the shim:

```bash
/root/blackflag/repos/blackflag-dnf/packaging/gen-base-provides.sh > /tmp/p.inc
sed -e '/@PROVIDES@/{r /tmp/p.inc' -e 'd}' \
    packaging/blackflag-base.spec.in > ~/rpmbuild/SPECS/blackflag-base.spec
rpmbuild -bb ~/rpmbuild/SPECS/blackflag-base.spec
rpm -Uvh --justdb --replacepkgs ~/rpmbuild/RPMS/*/blackflag-base-*.rpm
```

The generator excludes anything already owned by a real RPM, so the shim shrinks
on its own as conversion proceeds.

## Rotating or replacing the signing key

```bash
gpg --batch --gen-key key.batch                     # new key
gpg --armor --export "<uid>" > /etc/pki/rpm-gpg/RPM-GPG-KEY-blackflag-2.0
rpmkeys --import /etc/pki/rpm-gpg/RPM-GPG-KEY-blackflag-2.0
# ship BOTH keys in blackflag-release for one release cycle, then drop the old one
bf-repo sign  /srv/blackflag/repo/local/Packages/*.rpm   # re-sign everything
bf-repo update local
```

Never remove the old key from `blackflag-release` in the same release that
introduces the new one — clients that have not updated yet would stop trusting
the repository.

## Recovering from a broken transaction

```bash
dnf5 history                    # find the transaction id
dnf5 history undo <id>
rpm --rebuilddb                 # only if the rpmdb itself is suspect
```

`/var/lib/rpm/backup/` holds rpmdb backups taken before transactions.

## Sanity checks worth running after any change to rpm or its macros

```bash
bf-selftest                                  # 53 assertions, end to end
rpm --eval '%{_libdir}'                      # must be /usr/lib, NOT /usr/lib64
rpm --eval '%{?dist}'                        # must be .bf1
nm -D /usr/lib/librpmio.so.10 | grep pgpParsePkts   # must print something
```

That last one matters more than it looks: rpm will build and run perfectly well
with a stub OpenPGP backend that silently verifies nothing.
