# OpsFactory Offline Docker

This repository builds and packages the OpsFactory offline Docker delivery for
linux/amd64 environments.

The repository does not contain OpsFactory application source code. It expects an
OpsFactory source checkout to be available locally and produces a self-contained
offline package that includes:

- a prebuilt Docker image archive
- a Docker Compose runtime file
- load/start/status/stop and model-configuration helper scripts
- a README installation and operations runbook
- a build and sanitization report

## Build

By default, the build script looks for the OpsFactory source checkout next to
this repository:

```bash
../ops-factory
```

Build the offline package:

```bash
./scripts/build-offline-package-linux-amd64.sh
```

Use an explicit source checkout:

```bash
./scripts/build-offline-package-linux-amd64.sh --source-dir /path/to/ops-factory
```

Reassemble the package from an existing local image without rebuilding it:

```bash
./scripts/build-offline-package-linux-amd64.sh --skip-docker-build
```

The output is written to `dist/`.

## Runtime Target

- Image tag: `opsfactory:offline-YYYYMMDD-linux-amd64`
- Platform: `linux/amd64`
- Base OS: `openEuler 24.03 LTS SP3`
- goosed: `1.33.1`

The generated package is intended for target machines that already have Docker
Engine and the Docker Compose plugin installed. The target machine does not need
public network access.
