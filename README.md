# libpin

**Pin, materialize, build, and collect artifacts** for third-party libraries — with optional Linux write confinement (bubblewrap + Landlock).

libpin is a small toolkit you drop in as your project’s `third_party/` (or copy next to pins). It was battle-tested inside [VehicleExpenses](https://github.com/) against multi-hour Docker/NDK builds (OpenCV, rclone, Paddle-Lite, co-developed Kotlin libraries) and non-git file pins (model packs with mandatory `sha256`).

| Piece | Role |
|-------|------|
| `kit/fetch-deps` | Materialize git and/or `[[source]]` pins; RO/RW modes; run builds |
| `kit/get-artifacts` | Copy build products per `libpin.toml` `[[artifact]]` rows |
| `kit/libpin-sandbox` | Orchestrate **bwrap outer → Landlock inner** |
| `kit/libpin-bwrap` | bubblewrap mount jail (RO root + RW hole) |
| `kit/libpin-landlock` | Landlock LSM: mutation only under allowed dirs |
| `kit/example/` | Toy git-style pin (no network) |
| `kit/files-pin/` | Minimal non-git `[[source]]` pin |
| `examples/` | Same pins as documentation templates |
| `docs/` | Quickstart + format + sandbox deep dive + case study |

## Why

Prebuilt binaries without a clear **source identity + recipe + stable artifact path** fail audit and make “why is this `.so` different?” unanswerable. Custom flags, patches, and Docker stacks must be **reproducible as a process**, even when the binary is not bit-for-bit reproducible.

libpin standardizes:

1. **One layout** for every dependency (git or file sources).
2. **One pin file** (`libpin.toml`) — identity, build steps, artifact collection.
3. **Optional sandboxing** so materialize/build may only **mutate** a declared surface (read/exec stay free so toolchains work).
4. **Graceful degradation** — missing `bwrap` or Landlock → unsandboxed, still correct.

## 30-second try

```bash
cd kit   # this directory acts as third_party/
./fetch-deps ro example
./fetch-deps build example
cat example/artifact/hello.bin

./fetch-deps ro files-pin
cat files-pin/src/hello.txt
```

Full walkthrough: **[docs/QUICKSTART.md](docs/QUICKSTART.md)**.

## Docs map

| Document | Contents |
|----------|----------|
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | Install, first pin, common commands |
| [docs/PIN_FORMAT.md](docs/PIN_FORMAT.md) | `libpin.toml` reference (git, `[[source]]`, `[[artifact]]`) |
| [docs/GUIDE.md](docs/GUIDE.md) | Workflow, responsibilities, profiles, integration |
| [docs/SANDBOX.md](docs/SANDBOX.md) | bubblewrap + Landlock capabilities, modes, limits |
| [docs/CASE_STUDY_VEHICLEEXPENSES.md](docs/CASE_STUDY_VEHICLEEXPENSES.md) | Real multi-ABI / Docker / non-git pin stack |

## Drop into a consumer project

```bash
# From your app repo root
mkdir -p third_party
cp -a path/to/libpin/kit/* third_party/
# add your pins as third_party/<name>/ with libpin.toml
./third_party/fetch-deps ro mylib
./third_party/fetch-deps build mylib
```

Tools assume they live **in** the directory that contains pins (classically named `third_party/`). Parent of that directory is the **repo root** (for `app/…` artifact destinations).

## Requirements

| Need | Notes |
|------|--------|
| bash, python3 (3.11+ has `tomllib`; else `tomli`) | Core |
| git | Git pins |
| curl or wget | HTTPS `[[source]]` (optional) |
| **bubblewrap** (`bwrap`) | Optional; `apt install bubblewrap` |
| **Landlock** (kernel LSM) | Optional; `./libpin-landlock --status` |
| Linux | Sandbox helpers are Linux-only no-ops elsewhere |

## License

MIT — see [LICENSE](LICENSE). Extracted from in-tree VehicleExpenses `third_party/` tooling (2026).

## Status

Standalone packaging of production tooling. The pin contract and sandbox behavior match the in-tree VehicleExpenses copy; keep them in sync when either side changes.
