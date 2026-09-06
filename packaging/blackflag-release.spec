Name:           blackflag-release
Version:        1.0.0
Release:        1%{?dist}
Summary:        BlackFlag Linux release files and repository configuration

License:        MIT
URL:            https://blackflag.com.bd
Source0:        RPM-GPG-KEY-blackflag-1.0
Source1:        blackflag.repo

BuildArch:      noarch
Provides:       system-release = %{version}
Provides:       system-release(releasever) = 1.0
Provides:       blackflag-release(releasever) = 1.0
Provides:       redhat-release = %{version}

%description
BlackFlag Linux release files: /etc/os-release and friends, the distribution
package-signing public key, and the yum/dnf repository definitions used by dnf5.

Installing this package is what makes a machine identify itself as BlackFlag Linux
to dnf: it supplies system-release, which every other BlackFlag package requires,
and it pins $releasever.

%prep
%build

%install
install -d %{buildroot}%{_sysconfdir}
install -d %{buildroot}%{_sysconfdir}/pki/rpm-gpg
install -d %{buildroot}%{_sysconfdir}/yum.repos.d
install -d %{buildroot}%{_sysconfdir}/dnf/vars

install -Dpm0644 %{SOURCE0} %{buildroot}%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-blackflag-1.0
install -Dpm0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/yum.repos.d/blackflag.repo

echo -n "1.0" > %{buildroot}%{_sysconfdir}/dnf/vars/releasever

cat > %{buildroot}%{_sysconfdir}/os-release <<'EOF'
NAME="BlackFlag Linux"
VERSION="1.0.0 (Fajr)"
ID=blackflag
ID_LIKE=lfs
VERSION_ID=1.0.0
VERSION_CODENAME=fajr
PLATFORM_ID="platform:bf1"
PRETTY_NAME="BlackFlag Linux 1.0.0 (Fajr)"
ANSI_COLOR="1;33"
HOME_URL="https://blackflag.com.bd"
SUPPORT_URL="https://blackflag.com.bd/support"
BUG_REPORT_URL="https://blackflag.com.bd/bugs"
EOF

cat > %{buildroot}%{_sysconfdir}/blackflag-release <<'EOF'
BlackFlag Linux release 1.0.0 (Fajr)
EOF

%files
%config(noreplace) %{_sysconfdir}/os-release
%config(noreplace) %{_sysconfdir}/blackflag-release
%config(noreplace) %{_sysconfdir}/yum.repos.d/blackflag.repo
%config(noreplace) %{_sysconfdir}/dnf/vars/releasever
%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-blackflag-1.0

%changelog
* Sun Sep 06 2026 BlackFlag Build System <build@blackflag.com.bd> - 1.0.0-1
- Initial release: os-release, signing key, repository definitions
