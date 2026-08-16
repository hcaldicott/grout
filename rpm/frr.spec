# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Robin Jarry

%global frr_libdir %{_libexecdir}/frr

# FRR's large libtool links can make GCC's default -flto=auto wrapper lose the
# inherited make jobserver descriptors in constrained OBS workers. Preserve
# LTO while using one deterministic LTRANS worker instead of the jobserver.
%global _hardened_build 1
%global _lto_cflags -flto=1 -ffat-lto-objects
%global selinuxtype targeted
%define _legacy_common_support 1
%{!?version:%global version 10.6.1}

Name: frr
Version: %{version}
Release: 1%{?dist}.grout
Summary: Routing daemon
License: GPL-2.0-or-later AND ISC AND LGPL-2.0-or-later AND BSD-2-Clause AND BSD-3-Clause AND (GPL-2.0-or-later  OR ISC) AND MIT
URL: http://www.frrouting.org
Source0: %{name}-%{version}.tar.gz
Patch0: zebra-route-IPv4-link-local-neighbor-updates-through.patch
Patch1: zebra-route-EVPN-MH-L2-nexthops-through-dplane.patch
Patch2: zebra-reconcile-EVPN-MH-interface-MACs.patch

BuildRequires: autoconf
BuildRequires: automake
BuildRequires: bison >= 2.7
BuildRequires: flex
BuildRequires: gcc
BuildRequires: gcc-c++
BuildRequires: groff
BuildRequires: elfutils-libelf-devel
BuildRequires: json-c-devel
BuildRequires: libcap-devel
BuildRequires: libtool
BuildRequires: libxcrypt-devel
BuildRequires: libyang-devel >= 2.1.128
BuildRequires: make
BuildRequires: ncurses
BuildRequires: ncurses-devel
BuildRequires: openssl-devel
BuildRequires: pam-devel
BuildRequires: patch
BuildRequires: pcre2-devel
BuildRequires: protobuf-c-compiler
BuildRequires: protobuf-c-devel
BuildRequires: python3-devel
BuildRequires: readline-devel
BuildRequires: systemd-devel
BuildRequires: systemd-rpm-macros

Requires(pre): systemd
Requires(post): systemd
Requires(postun): systemd
Requires(preun): systemd

Obsoletes: quagga < 1.2.4-17
Provides: routingdaemon = %{version}-%{release}

%description
FRRouting is free software that manages TCP/IP based routing protocols. It takes
a multi-server and multi-threaded approach to resolve the current complexity
of the Internet.

FRRouting supports BGP4, OSPFv2, OSPFv3, ISIS, RIP, RIPng, PIM, NHRP, PBR,
EIGRP and BFD.

FRRouting is a fork of Quagga.

%package headers
Summary: Build headers for FRR
BuildArch: noarch
Requires: json-c-devel
Requires: libyang-devel

%description headers
Build headers for FRR required to generate out of tree dplane plugins

%prep
%autosetup -n %{name}-%{name}-%{version} -p1

%build
# FRR 10.6.1 trips a GCC 15/annobin LTO ICE when built with GCC Toolset 15,
# which build environments may put first in PATH for Grout. OBS normally
# builds FRR with the EL9 system compiler. Pin FRR to that compiler so local
# source-package validation and OBS use the same supported toolchain.
%if 0%{?rhel} == 9
export PATH=/usr/bin:/usr/sbin:$PATH
export CC=/usr/bin/gcc
export CXX=/usr/bin/g++
%endif
export CFLAGS="%{optflags} -DINET_NTOP_NO_OVERRIDE"
autoreconf -ivf

%configure \
	--sbindir=%{frr_libdir} \
	--libdir=%{_libdir}/frr \
	--libexecdir=%{_libexecdir}/frr \
	--runstatedir=%{_rundir} \
	--with-crypto=openssl \
	--with-moduledir=%{_libdir}/frr/modules \
	--with-pkgconfigdir=%{_datadir}/pkgconfig \
	--with-vtysh-pager=less \
	--with-yangmodelsdir=%{_datadir}/frr-yang/ \
	--disable-babeld \
	--disable-doc \
	--disable-nhrpd \
	--disable-pathd \
	--disable-pbrd \
	--enable-multipath=64 \
	--enable-pcre2posix \
	--enable-user=frr \
	--enable-group=frr \
	--enable-vty-group=frr

# GCC's LTO wrapper inherits GNU make's jobserver through libtool. FRR's
# nested libtool links can close those descriptors before lto-wrapper uses
# them, so run this control-plane package serially while retaining LTO.
%make_build -j1 PYTHON=%{__python3}

%install
%make_install

# FRR's public headers conditionally include the generated configuration when
# HAVE_CONFIG_H is present.  External dataplane plugins need the same contract
# as in-tree modules; without it, inline helpers in headers such as ipaddr.h
# use FRR's strlcpy/strlcat implementations without visible prototypes.
install -Dpm 644 config.h %{buildroot}%{_includedir}/frr/config.h
sed -i '/^Cflags:/ s/$/ -DHAVE_CONFIG_H/' %{buildroot}%{_datadir}/pkgconfig/frr.pc

# Remove this file, as it is uninstalled and causes errors when building on RH9
rm -rf %{buildroot}%{_infodir}/dir

install -Dpm 644 tools/etc/frr/daemons %{buildroot}%{_sysconfdir}/frr/daemons
install -Dpm 644 tools/frr.service %{buildroot}%{_unitdir}/frr.service
install -Dpm 755 tools/frrinit.sh %{buildroot}%{frr_libdir}/frr
install -Dpm 755 tools/frrcommon.sh %{buildroot}%{frr_libdir}/frrcommon.sh
install -Dpm 755 tools/watchfrr.sh %{buildroot}%{frr_libdir}/watchfrr.sh
install -Dpm 644 redhat/frr.logrotate %{buildroot}%{_sysconfdir}/logrotate.d/frr
install -Dpm 644 redhat/frr.pam %{buildroot}%{_sysconfdir}/pam.d/frr
install -dm 775 %{buildroot}/run/frr
install -dm 775 %{buildroot}/var/log/frr
install -dm 775 %{buildroot}/var/lib/frr
install -dm 755 %{buildroot}%{_tmpfilesdir}
install -dm 755 %{buildroot}%{_sysusersdir}

cat > %{buildroot}%{_sysusersdir}/%{name}.conf <<EOF
u frr - "FRRouting routing suite" /var/run/frr /sbin/nologin
EOF
cat > %{buildroot}%{_tmpfilesdir}/%{name}.conf <<EOF
d /run/frr 0755 frr frr -
d /var/log/frr 0755 frr frr -
d /var/lib/frr 0755 frr frr -
EOF

touch %{buildroot}%{_sysconfdir}/frr/frr.conf
touch %{buildroot}%{_sysconfdir}/frr/vtysh.conf

# Delete libtool archives
find %{buildroot} -type f -name "*.la" -delete -print
find %{buildroot} -type f -name "*.a" -delete -print

# Upstream does not maintain a stable API
rm %{buildroot}%{_libdir}/frr/*.so

%pre
systemd-sysusers - <<EOF
u frr - "FRRouting routing suite" /run/frr /sbin/nologin
EOF

%post
%systemd_post frr.service

%postun
%systemd_postun_with_restart frr.service

%preun
%systemd_preun frr.service

%files
%license COPYING
%dir %attr(750,frr,frr) %{_sysconfdir}/frr
%dir %attr(755,frr,frr) /run/frr
%dir %attr(755,frr,frr) /var/log/frr
%dir %attr(755,frr,frr) /var/lib/frr
%dir %{frr_libdir}/
%{frr_libdir}/*
%{_bindir}/mtracebis
%{_bindir}/vtysh
%dir %{_libdir}/frr
%{_libdir}/frr/*.so.*
%dir %{_libdir}/frr/modules
%{_libdir}/frr/modules/*
%config(noreplace) %attr(644,root,root) %{_sysconfdir}/logrotate.d/frr
%config(noreplace) %attr(644,frr,frr) %{_sysconfdir}/frr/daemons
%config(noreplace) %attr(644,frr,frr) %{_sysconfdir}/frr/frr.conf
%config(noreplace) %attr(644,frr,frr) %{_sysconfdir}/frr/vtysh.conf
%config(noreplace) %{_sysconfdir}/pam.d/frr
%{_unitdir}/*.service
%dir %{_datadir}/frr-yang
%{_datadir}/frr-yang/*.yang
%{_sysusersdir}/%{name}.conf
%{_tmpfilesdir}/%{name}.conf

%files headers
%dir %{_includedir}/frr/
%{_includedir}/frr/*
%{_datadir}/pkgconfig/frr.pc

%changelog
* Thu Apr 02 2026 Robin Jarry <rjarry@redhat.com>
- Version shipped with grout
