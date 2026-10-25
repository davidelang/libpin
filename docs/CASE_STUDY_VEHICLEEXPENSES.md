# Case study: VehicleExpenses third_party stack

How libpin is used in a **real, complex** Android/native monorepo: multiple profiles, multi-hour Docker builds, non-git model packs, multi-ABI artifacts, and co-developed libraries.

This is a narrative snapshot of practices proven in-tree (2026). Paths refer to a VehicleExpenses worktree layout; the **contract** is exactly what this libpin kit implements.

---

## Inventory

| Pin | Kind | build_time | Notes |
|-----|------|------------|--------|
| **opencv** | git | tens_of_minutes | Options-only CMake/NDK; slim modules; arm64 + x86_64 |
| **rclone** | git + patches | tens_of_minutes – few_hours | Wrapper patches; ± Docker / gomobile-style |
| **paddle** | git (fork) + many patches | few_hours | Docker NDK r28c; three ABIs; tailor; strip |
| **paddle-models** | `source_kind = files` | minutes | Tailor/opt `.nb` + kernel lists; sha256 pins |
| **remotetable / extractmail** | git, often `rw` | minutes – tens_of_minutes | Co-dev Kotlin AAR; extractmail nests remotetable |
| **example** | seed git toy | minutes | Smoke / docs |

Shared tooling at `third_party/{fetch-deps,get-artifacts,libpin-*}`.

---

## Happy path (app developer)

```bash
# From VehicleExpenses worktree root
./third_party/fetch-deps ro opencv paddle-models
./third_party/fetch-deps build opencv

# Heavy pin — long Docker build; skip image rebuild when iterating
./third_party/fetch-deps ro paddle
PADDLE_SKIP_IMAGE_BUILD=1 PADDLE_DOCKER_IMAGE=ve-paddle-ndk28c \
  PADDLE_NDK_VERSION=r28c PADDLE_ABIS="arm64-v8a armeabi-v7a x86_64" \
  ./third_party/paddle/build
./third_party/get-artifacts paddle
```

After collect:

- Pin-local audit copies under `third_party/paddle/artifact/jni/…`
- App promote copies under `app/src/main/jniLibs/…` (independent `[[artifact]]` rows, same `from`)

---

## Non-git pin: paddle-models

Tailor inputs are **not** a git tree of upstream models. They are fixed binary/list files with mandatory hashes:

```toml
name = "paddle-models"
source_kind = "files"
build = []

[[source]]
seed = "seed/armv7/det_armv7.nb"
path = "armv7/det_armv7.nb"
sha256 = "fb6aa7b7…"
```

```bash
./third_party/fetch-deps ro paddle-models
# → third_party/paddle-models/src/armv7|armv8|x86_64/…
```

**Hash policy in production:** if a seed/url no longer matches `sha256`, fetch-deps re-fetches **once**, then **hard fails**. Maintainers update the hash (and seed) deliberately — no infinite “wait for old bytes.”

paddle’s `./build` prefers `paddle-models` layout when present; falls back to in-pin `tailor_models/`.

---

## Complex git pin: paddle

### Identity

- Fork commit (upstream + stacked product branches/PRs)
- Full historical `patches/` + `patches-int8/` (+ x86 OpenBLAS series as needed)
- `reproducible = false` (NDK, Docker base, timestamps)
- `build_time = "few_hours"`

### Multi-ABI product matrix (illustrative)

| ABI | Profile | Notes |
|-----|---------|--------|
| arm64-v8a | tailor + HW fp16 | Matches armv8 u8/fp16 models |
| armeabi-v7a | tailor + **fp32 calib only** | True ARMv7 head units — no ARM82 fp16 product path |
| x86_64 | slim thin-jni + full light | Emulator/AMD64; **do not default tailor** (LTO/gc drops KernelRegistrar) |

Artifact rows include both:

1. **Pin-local** `artifact/jni/<abi>/…` + required `sha256` for audit
2. **App promote** `app/src/main/jniLibs/<abi>/…` with the same content hash

### Build confinement

Materialize and `./build` run under `libpin-sandbox` (pass `--no-bwrap --no-landlock` only when the tools are missing):

- materialize → mode `lib` (write under `third_party/paddle/`)
- build → mode `src` (mutation under `third_party/paddle/src/`)
- Docker socket bound through bwrap so the containerized NDK build can talk to the host daemon
- get-artifacts **unsandboxed** so `app/…` promote works

---

## Co-development: remotetable / extractmail

Same pin layout while actively editing library sources next to the app:

```bash
./third_party/fetch-deps rw remotetable
# edit third_party/remotetable/src/…
./third_party/fetch-deps build remotetable
```

- RO unlocks only Gradle/build dirs as needed; sources default RO on audit rebuilds
- `reproducible = true` when same toolchain yields bit-identical AARs
- extractmail **vendors** remotetable under its own `third_party/` with a **copy** of libpin tools (nested consumer pattern)

---

## Optional local git (`GIT_HOME`)

Maintainers often keep full clones under `~/git/opencv`, `~/git/Paddle-Lite`, etc. When that host is a readable git repo, fetch-deps clones it with `--no-hardlinks` into `third_party/<lib>/src` (offline shortcut). If the host is missing or unreadable, that is a declared loud fallback: print chmod/setfacl/ssh for a user other than the agent (never chown/chgrp) and use `git_https` / `git_ssh`. Host `.git` is read-only inside the sandbox (no `LIBPIN_HOST_GIT` RW bind). opencv’s object store is copied per worktree (~573M); that is accepted.

`rclone` and `paddle` need `default = false` to stay out of the default NAME set. `paddle-opt` already has `host_repo = "paddle"`; its 64-zero sha256 must be filled by `--record`. `extractmail` should add `depends = ["remotetable"]`. opencv `track_branch = "4.10.0"` is a tag check (`refresh` fails if the tag moves; `upgrade --ref` to change it).

Joe Random without `GIT_HOME` still materializes via `git_https`, or `git_ssh` if that is the only remote.

---

## Smoke and integration testing

Beyond “does the pin build,” VehicleExpenses added:

- **Host ELF / QEMU user-mode** smoke for prebuilt Paddle SOs (all three ABIs), including armv7 PID quirks under bwrap (`--as-pid-1` for Bionic PID ≤ 65535)
- Integration of that smoke into the paddle pin’s test target after collect
- Emulator (AVD) and real hardware remain **opportunistic full-app** tests — not the first line for “does this `.so` load”

libpin itself does not mandate QEMU; the case study shows how **artifact collect** feeds downstream smoke harnesses.

---

## Lessons encoded in libpin

1. **One layout** for options-only, patch-heavy, Docker-heavy, file-only, and co-dev pins.
2. **`libpin.toml` is the contract** — mode is `status.local`, not the pin file.
3. **Non-git sources need the same discipline as git** — content hash is the pin; fail closed.
4. **Independent `[[artifact]]` rows** — pin-local audit vs app promote without a second tool.
5. **Sandbox is required unless both `--no-bwrap` and `--no-landlock` are passed** — mutation surfaces are explicit; host clones stay read-only.
6. **Document ABI product policy in SOURCE.md** — e.g. “true v7 has no product soft-fp16”; tailor is the size lever.
7. **Nested consumers copy the kit** until libpin is a published dependency.

---

## Mapping back to this repo

| VE path | libpin extract |
|---------|----------------|
| `third_party/fetch-deps` | `kit/fetch-deps` |
| `third_party/get-artifacts` | `kit/get-artifacts` |
| `third_party/libpin-*` | `kit/libpin-*` |
| `third_party/example` | `kit/example` + `examples/` |
| `docs/reference/THIRD_PARTY_PIN_BUILDS.md` | `docs/GUIDE.md` + `docs/PIN_FORMAT.md` |
| paddle / paddle-models narrative | this case study |

To re-sync tools from a VE worktree:

```bash
cp -a $VE/third_party/fetch-deps \
      $VE/third_party/get-artifacts \
      $VE/third_party/libpin-sandbox \
      $VE/third_party/libpin-bwrap \
      $VE/third_party/libpin-landlock \
      path/to/libpin/kit/
```
