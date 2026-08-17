# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2024 Robin Jarry

%bcond_with docs
%bcond_without tests
%bcond_without systemd
%bcond_without frr
%bcond_with download

# OBS builds do not inject the GNUmakefile's version/release macros. Keep
# explicit snapshot defaults while allowing local `make rpm` to override them.
%{!?version:%global version 0.16.3}
%{!?release:%global release 0.1.evpnmh.g38e00bd9%{?dist}}

%define dpdk_cpu generic
%ifarch x86_64
%if 0%{?rhel} >= 9
%define dpdk_cpu x86-64-v2
%endif
%if 0%{?rhel} >= 10
%define dpdk_cpu x86-64-v3
%endif
%endif

%undefine _debugsource_packages
# Grout uses constructors and linker-defined registration contracts that are
# not currently safe under LTO. Distro-wide LTO also breaks linker-wrapped
# unit tests and makes bundled DPDK builds prohibitively expensive.
%global _lto_cflags %nil
%global branch main
%if %{with download}
%global __meson_wrap_mode default
%endif

Name: grout
Summary: Graph router based on DPDK
Group: System Environment/Daemons
URL: https://github.com/hcaldicott/grout
License: BSD-3-Clause AND GPL-2.0-or-later
Version: %{version}
Release: %{release}
Source0: %{name}-%{version}.tar.gz

BuildRequires: gcc
%if 0%{?rhel} == 9
BuildRequires: gcc-toolset-15-gcc
BuildRequires: gcc-toolset-15-gcc-c++
BuildRequires: gcc-toolset-15-gcc-plugin-annobin
%endif
%if %{with download}
BuildRequires: git
%endif
%if %{with docs}
BuildRequires: scdoc
%endif
BuildRequires: libarchive-devel
BuildRequires: libbpf-devel
BuildRequires: elfutils-libelf-devel
%if %{with tests}
BuildRequires: libcmocka-devel
%endif
BuildRequires: libedit-devel
BuildRequires: libevent-devel
BuildRequires: libmnl-devel
BuildRequires: meson
BuildRequires: ninja-build
BuildRequires: numactl-devel
BuildRequires: openssl-devel
BuildRequires: pkgconf
BuildRequires: python3-pyelftools
BuildRequires: rdma-core-devel
%if %{with frr} && %{without download}
BuildRequires: frr-headers >= 10.5
%endif
%if %{with systemd}
BuildRequires: systemd
BuildRequires: systemd-devel
BuildRequires: systemd-rpm-macros
%endif

Requires: less

%description
grout stands for Graph Router. In English, "grout" refers to thin mortar that
hardens to fill gaps between tiles.

grout is a DPDK based network processing application. It uses the rte_graph
library for data path processing.

Its main purpose is to simulate a network function or a physical router for
testing/replicating real (usually closed source) VNF/CNF behavior with an
opensource tool.

It comes with a client library to configure it over a standard UNIX socket and
a CLI that uses that library. The CLI can be used as an interactive shell, but
also in scripts one command at a time, or by batches.

%package headers
Summary: Development headers for building grout API clients
BuildArch: noarch
Suggests: %{name}

%description headers
This package contains the development headers to build grout API clients.

%if %{with frr}
%package frr
Summary: FRR dplane plugin for grout
Requires: frr = %(rpm -q --qf '%%{version}-%%{release}' frr-headers)

%description frr
FRR dplane plugin for grout
%endif

%prep
%autosetup -n %{name}-%{version}

%build
%if 0%{?rhel} == 9
export PATH=/opt/rh/gcc-toolset-15/root/usr/bin:$PATH
export CC=/opt/rh/gcc-toolset-15/root/usr/bin/gcc
export CXX=/opt/rh/gcc-toolset-15/root/usr/bin/g++
%endif
export GROUT_VERSION="%{version}-%{release}"
%meson \
%if %{with tests}
	-Dtests=enabled \
%else
	-Dtests=disabled \
%endif
%if %{with docs}
	-Ddocs=enabled \
%else
	-Ddocs=disabled \
%endif
%if %{with frr}
	-Dfrr=enabled \
%else
	-Dfrr=disabled \
%endif
	-Ddpdk_cpu=%{dpdk_cpu}

%meson_build

%check
%if %{with tests}
%meson_test

# Unit tests do not exercise the real module-constructor and netlink startup
# path. Keep a short daemon smoke test here so unsafe compiler/linker
# optimizations fail the package build before reaching a host.
grout_bin=$(find . -maxdepth 2 -type f -name grout -perm -111 -print -quit)
test -n "$grout_bin"
GROUT_MEMPOOL_CACHE_SIZE=64 "$grout_bin" --version
if GROUT_MEMPOOL_CACHE_SIZE=513 "$grout_bin" --version; then
	echo "out-of-range mempool cache size was accepted" >&2
	exit 1
fi
smoke_socket="$PWD/grout-smoke.sock"
smoke_log="$PWD/grout-smoke.log"
set +e
timeout --signal=TERM 3s env GROUT_MEMPOOL_CACHE_SIZE=64 "$grout_bin" -t -s "$smoke_socket" \
	-M tcp:127.0.0.1:0 -- -m 128 >"$smoke_log" 2>&1
smoke_rc=$?
set -e
cat "$smoke_log"
test "$smoke_rc" -eq 124
rm -f "$smoke_socket" "$smoke_log"
%endif

%install
%meson_install --skip-subprojects
%if %{without systemd}
rm -rf %{buildroot}%{_sysconfdir} %{buildroot}%{_unitdir}
%endif

%if %{with systemd}
%post
%systemd_post %{name}.service

%preun
%systemd_preun %{name}.service
%endif

%files
%doc README.md
%license licenses/BSD-3-clause.txt
%if %{with systemd}
%config %{_sysconfdir}/default/grout
%config %{_sysconfdir}/grout.init
%attr(644, root, root) %{_unitdir}/grout.service
%endif
%attr(644, root, root) %{_datadir}/bash-completion/completions/grout
%attr(644, root, root) %{_datadir}/bash-completion/completions/grcli
%attr(755, root, root) %{_bindir}/grcli
%attr(755, root, root) %{_bindir}/grout
%if %{with docs}
%attr(644, root, root) %{_mandir}/man1/grcli*.1*
%attr(644, root, root) %{_mandir}/man8/grout.8*
%endif

%files headers
%doc README.md
%license licenses/BSD-3-clause.txt
%{_datadir}/pkgconfig/grout.pc
%{_includedir}/grout/*.h

%if %{with frr}
%files frr
%doc README.md
%license licenses/GPL-2.0-or-later.txt
%attr(755, root, root) %{_libdir}/frr/modules/dplane_grout.so
%if %{with systemd}
%attr(644, root, root) %{_unitdir}/frr.service.d/grout.conf
%endif
%if %{with docs}
%attr(644, root, root) %{_mandir}/man7/grout-frr.7*
%endif
%endif

%changelog
* Mon Sep 02 2024 Robin Jarry <rjarry@redhat.com>
- Nightly build
