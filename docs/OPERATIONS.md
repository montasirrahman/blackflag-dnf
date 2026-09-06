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

---

# Recovery

## If `bash` will not start

```
/bin/bash: error while loading shared libraries: libX.so.N: cannot open shared object file
```

Nothing on the machine works at this point — not `ssh` (sshd runs every login,
command, `scp` and external `sftp-server` through the login shell), not `sudo`.
You need a hypervisor, serial or IPMI console.

The usual cause is a missing symlink rather than a missing library, and the fix
is one line:

```bash
ln -sfn libreadline.so.8.3 /usr/lib/libreadline.so.8 && ldconfig
```

Check before assuming the library is gone — `ls /usr/lib/libreadline.so.*` will
usually show the real `.so.8.3` file sitting there intact.

### How this happens, and how not to cause it

An install that replaces a shared library often renames the previous one to
`.old` rather than deleting it. Both files then carry the **same SONAME**, and
`ldconfig` may point the `.so.N` symlink at *either*. If it picks the `.old` copy
and you then tidy those up:

```bash
rm -f /usr/lib/*.so.*.old     # <-- do not do this
```

the symlink is orphaned and every program linking that library stops working —
including your shell.

Resolve what the link actually points at before deleting anything in a library
directory:

```bash
readlink -f /usr/lib/libreadline.so.8      # where does it really go?
rm -f /usr/lib/libreadline.so.8.3.old      # then remove by exact name
ldconfig && ls -l /usr/lib/libreadline.so.8
```

## Restoring from the rollback snapshot

Stage 80 refuses to install without one:

```bash
tar -I 'zstd -3 -T2' -cf /root/blackflag/backup/pre-basepkgs-usr-etc.tar.zst \
    /usr /etc /var/lib/rpm
```

Restore everything, or just the paths that changed:

```bash
# what has been modified since a known-good moment
find /usr /etc -xdev \( -type f -o -type l \) -newermt "2026-09-06 16:45" \
  | sed 's|^/||' > /tmp/leaked.txt

cd / && tar -I zstd -xf /root/blackflag/backup/pre-basepkgs-usr-etc.tar.zst \
        --files-from=/tmp/leaked.txt
ldconfig
```

Paths reported as "Not found in archive" did not exist before and should be
deleted rather than restored.

## Confirming the system is actually healthy again

```bash
bf-selftest                 # 53 assertions across rpm, dnf5, signing, round trip
rpm -Va                     # only %config files and /usr/share/info/dir should differ
rpm --verifydb
```

`rpm -Va` output is normal when it shows `S.5....T.  c /etc/...` for config files
(`%config(noreplace)` keeps yours) and `S.5......  d /usr/share/info/dir` (every
info-installing package appends to that index). Any `M` (mode), `L` (symlink) or
`missing` line is not normal.

## Why builds must never install to the live system

`bf-repack` stages every install into a buildroot and refuses to continue if
anything under `/usr`, `/etc`, `/bin`, `/sbin`, `/lib` or `/opt` was modified
during it. If you see:

```
REFUSING TO CONTINUE: the install wrote OUTSIDE the staging directory.
```

that build system ignores `DESTDIR`. Re-run it with an explicit staging prefix
and restore the listed paths first:

```bash
bf-repack foo 1.0 /path/to/src make install "PREFIX=@BUILDROOT@/usr"
```

Passing `DESTDIR` in the environment is **not** sufficient: GNU make ranks
command line above makefile above environment, so a Makefile containing a bare
`DESTDIR =` silently discards it and installs into the real prefix.
