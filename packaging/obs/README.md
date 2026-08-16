# OBS packaging

This directory defines the signed AlmaLinux 9 x86_64 build for the EVPN-MH
Grout fork. The production repository is intentionally separate from the
OpenNebula VNM plugin repository because it also owns a patched FRR runtime.

Run `packaging/obs/prepare-sources.sh` from a checkout containing the verified
Meson package-cache downloads. It creates ignored artifacts under `dist/obs`.

Upload these files to the unpublished `Grout:Staging:AlmaLinux9.8` project:

- package `frr`: `dist/obs/frr.spec`, `dist/obs/frr-10.6.1.tar.gz`, and the
  three renamed patches in `dist/obs`;
- package `grout`: `dist/obs/grout.spec` and
  `dist/obs/grout-0.16.3.tar.gz`.

OBS builds `frr` first because `grout` requires the resulting `frr-headers`.
The Grout source archive embeds only the checksum-verified DPDK and libecoli
release archives required by Meson's offline wrap mode. It does not embed the
FRR source because FRR is independently packaged and updateable.

Promote the same successful source revisions to the signed `Grout` production
project. Installing the RPMs does not enable or start either service. NIC
binding, service activation, FRR configuration, and OpenNebula VNM activation
remain separate, explicitly reviewed deployment steps.
