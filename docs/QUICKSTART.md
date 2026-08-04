# libpin quickstart

Get a working pin in minutes. No network required for the bundled examples.

## 1. Prerequisites

```bash
# Core
python3 --version   # 3.11+ preferred (tomllib); or pip install tomli
bash --version
git --version

# Optional sandbox (Linux) — tools still work without these
sudo apt install bubblewrap    # provides `bwrap`
# Landlock is a kernel feature; check:
./kit/libpin-landlock --status
# → "available abi=N" or "unavailable"
```

## 2. Layout mental model

```text
third_party/                 ← kit/ dropped here (or use kit/ in place)
  fetch-deps
  get-artifacts
  libpin-sandbox | libpin-bwrap | libpin-landlock
  example/                   ← a pin
    libpin.toml
    SOURCE.md
    patches/
    build
    src/                     ← materialized (usually not committed)
    artifact/                ← stable outputs consumers link
  files-pin/                 ← non-git pin
  mylib/                     ← your pin
```

| Path | Role |
|------|------|
| `libpin.toml` | Pin identity + build + artifact rules |
| `src/` | Sources after materialize |
| `artifact/` | Stable names for the app / other consumers |
| `patches/` | Applied **only** by `fetch-deps` at materialize |
| `status.local` | Local RO/RW mode (gitignored; not part of the pin) |

## 3. Run the toy example

```bash
cd kit    # or: cd your-repo/third_party

# Materialize (creates tiny git tree in example/src from seed-src; applies patch)
./fetch-deps ro example

# Build + collect → example/artifact/hello.bin
./fetch-deps build example

cat example/artifact/hello.bin
# → hello from third_party/example pin 0.0.1 at <timestamp>
```

Iterate a build without re-materializing:

```bash
./example/build
./get-artifacts example
```

## 4. Non-git file pin

```bash
./fetch-deps ro files-pin
cat files-pin/src/hello.txt
# → Hello from a non-git [[source]] pin.
```

`files-pin` uses `source_kind = "files"` and `[[source]]` rows with `seed` + required `sha256`. No git, no SSH. See [PIN_FORMAT.md](PIN_FORMAT.md).

## 5. Add your own pin

```bash
mkdir -p mylib
```

Minimal **git** pin (`mylib/libpin.toml`):

```toml
name = "mylib"
git_https = "https://github.com/example/mylib.git"
git_sha = "0123456789abcdef0123456789abcdef01234567"
git_describe = "v1.0.0"
reproducible = false
build_time = "minutes"
requires_writable_src = false
build = ["./build"]
consumer_note = "Builds libfoo.so for our app"

[[artifact]]
path = "artifact/libfoo.so"
from = "src/build/libfoo.so"
```

Minimal **file** pin:

```toml
name = "assets"
source_kind = "files"
reproducible = true
build_time = "minutes"
build = []

[[source]]
seed = "seed/model.bin"          # offline copy under the pin dir
# url = "https://example.com/model.bin"  # optional; never git@ / ssh
path = "model.bin"               # under src/ after materialize
sha256 = "…"                     # required; pin is the hash
```

Add `mylib/build` (executable) that writes products under `src/…`, then:

```bash
./fetch-deps ro mylib
./fetch-deps build mylib
```

## 6. Everyday commands

```text
./fetch-deps ro [NAME…]       # pin + patches + sources RO (default)
./fetch-deps rw [NAME…]       # writable for co-development
./fetch-deps build [NAME…]    # run build[] + get-artifacts
./fetch-deps status [-v]      # mode / HEAD / dirty
./get-artifacts [NAME…]       # collect only (iterate builds)
```

Disable sandbox when debugging:

```bash
LIBPIN_NO_BWRAP=1 LIBPIN_NO_LANDLOCK=1 ./fetch-deps build example
# or:  ./fetch-deps --no-bwrap --no-landlock build example
```

Debug what the sandbox would do:

```bash
LIBPIN_BWRAP_DEBUG=1 LIBPIN_LANDLOCK_DEBUG=1 ./fetch-deps ro example
```

## 7. What “good” looks like

- Fresh clone: commit `libpin.toml`, `build`, `patches/`, often `artifact/*`.
- Do **not** commit a full dump of upstream `src/` (materialize with fetch-deps).
- Build scripts **do not** apply patches (fetch-deps already did).
- App-consumed binaries live under `artifact/` (and/or `app/…` rows), not only under `src/`.

## Next

- [PIN_FORMAT.md](PIN_FORMAT.md) — every field
- [GUIDE.md](GUIDE.md) — workflows, profiles, multi-consumer
- [SANDBOX.md](SANDBOX.md) — Landlock + bubblewrap in depth
- [CASE_STUDY_VEHICLEEXPENSES.md](CASE_STUDY_VEHICLEEXPENSES.md) — complex real stack
