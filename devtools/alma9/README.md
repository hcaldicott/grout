# AlmaLinux 9 development environment

The development container builds and tests grout on AlmaLinux 9.8 without
changing the host. It uses the native arm64 platform by default. Set
`PLATFORM=linux/amd64` for an SE350-compatible build under emulation.
The arm64 image uses DPDK's portable `generic` platform and CPU targets.

Build grout and its bundled FRR and DPDK dependencies:

```
devtools/alma9.sh build
```

Builds use four parallel jobs by default to stay within Docker Desktop memory
limits. Set `JOBS` to tune the concurrency.

Run the unit and smoke test suites:

```
devtools/alma9.sh test
```

Open a development shell or run an individual command:

```
devtools/alma9.sh shell
devtools/alma9.sh make SMOKE_MATCH=evpn smoke-tests
```

The container is privileged so the smoke tests can create network and mount
namespaces, TAP devices, and virtual links. It cannot validate X710 hardware,
VFIO/IOMMU configuration, NUMA placement, or physical line-rate performance.
