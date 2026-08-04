# libpin.toml — pin format reference

`libpin.toml` is the **pin contract**: identity, how to build, and how to collect artifacts. It is **not** machine-specific (no “this laptop’s paths”). Checkout mode (RO/RW) lives in gitignored `status.local`.

Format: **TOML** (no significant indentation). Filename ties to the tooling name *libpin*.

---

## Top-level fields

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `name` | string | yes | Library id; directory name under `third_party/` |
| `git_https` | string | for git pins | HTTPS clone URL |
| `git_ssh` | string | optional | `git@…` only with `--allow-ssh` / maintainer machines |
| `git_sha` | string | for git pins | Locked commit (full SHA preferred) |
| `git_describe` | string | optional | Human label (tag / describe) |
| `track_branch` | string | optional | Branch the pin usually tracks |
| `source_kind` | string | optional | `"files"` for pure non-git pins; omit for git |
| `reproducible` | bool / string | recommended | `true` \| `false` \| `"unknown"` — bit-identical artifacts expected? |
| `build_time` | string | recommended | t-shirt size (see below) |
| `requires_writable_src` | bool | optional | Default `false`. If `true`, leave `src` writable after materialize |
| `build` | array of strings | optional | Commands run from the pin dir; `[]` = materialize-only |
| `consumer_note` | string | optional | One-line note for humans / agents |
| `patches` | array of strings | optional | Explicit patch order; else `patches/*.patch` sorted by name |

### `build_time` values

| Value | Meaning |
|-------|---------|
| `minutes` | Roughly under ~10 minutes |
| `tens_of_minutes` | ~10–60 minutes |
| `few_hours` | ~1–4 hours |
| `tens_of_hours` | Long Docker / full SDK rebuilds |

### Git transport policy

- **Default:** HTTPS only (`git_https`).
- **SSH (`git@`):** only when the operator passes `--allow-ssh` (or equivalent maintainer policy). File `[[source]]` URLs **never** use SSH.

---

## Git pin example

```toml
name = "opencv"
git_ssh = "git@github.com:opencv/opencv.git"
git_https = "https://github.com/opencv/opencv.git"
git_sha = "71d3237a093b60a27601c20e9ee6c3e52154e8b1"
git_describe = "4.10.0"
track_branch = "4.10.0"

reproducible = false
build_time = "tens_of_minutes"
requires_writable_src = false
build = ["./build"]
consumer_note = "Android ABIs; 16k pages; slim modules"

[[artifact]]
path = "artifact/jni/arm64-v8a/libopencv_java4.so"
from = "src/bin/arm64-v8a/libopencv_java4.so"
sha256 = "…"   # optional; fail row if mismatch

[[artifact]]
path = "app/src/main/jniLibs/arm64-v8a/libopencv_java4.so"
from = "src/bin/arm64-v8a/libopencv_java4.so"
```

---

## Non-git pins: `[[source]]`

For content that is not a git tree (model packs, tarball extracts, fixed binaries):

```toml
name = "paddle-models"
source_kind = "files"
reproducible = true
build_time = "minutes"
requires_writable_src = false
build = []
consumer_note = "Tailor / opt .nb inputs per ABI"

[[source]]
seed = "seed/armv8/det_armv8.nb"   # offline copy under the pin directory
# url = "https://example.com/det_armv8.nb"
path = "armv8/det_armv8.nb"        # under src/ after materialize
sha256 = "…"
```

### `[[source]]` fields

| Field | Required | Meaning |
|-------|----------|---------|
| `path` | yes | Destination under `src/` |
| `sha256` | yes | Content hash (hex). **This is the pin.** |
| `seed` | one of seed/url | Path under the pin dir (copied) |
| `url` | one of seed/url | `https://…`, `http://…`, `file:relative`, `file:///abs` — **never** `git@` / SSH |

### Hash policy

1. Cache hit only if on-disk bytes match `sha256`.
2. Stale or missing → **one** re-fetch (or re-copy from seed).
3. Still wrong → **hard fail**. fetch-deps will not spin waiting for a remote to “become” the old hash.
4. When a remote moves, **update `sha256` (and seed)** in `libpin.toml`.

---

## Artifacts: `[[artifact]]`

Each section is independent (same `from` may appear twice with different `path`).

| Field | Required | Meaning |
|-------|----------|---------|
| `path` | yes | Destination (see resolution) |
| `from` | yes | Source under the pin dir after build (may be a **glob**) |
| `pick` | for globs | `newest` (mtime, **default**), `sort`, `sort-n` |
| `sha256` | optional | Fail that row if resolved content mismatches |

### `path` resolution

| `path` | Resolved as |
|--------|-------------|
| `artifact/…` or other pin-relative | `third_party/<lib>/<path>` |
| `app/…` | `<repo-root>/app/…` (e.g. Android jniLibs) |
| absolute | as written |

### Glob + `pick`

```toml
[[artifact]]
path = "artifact/hello.bin"
from = "src/bin/hello-*.bin"
pick = "newest"
```

If `from` is not a glob, `pick` is ignored. Table name is singular **`[[artifact]]`**.

### Reproducible builds

- `reproducible = true` — same pin + patches + scripts expected to yield **bit-for-bit** identical artifacts (rare). Artifact `sha256` is a strong audit check.
- `false` / `unknown` — process is still reproducible; bytes may vary (timestamps, NDK, Docker base). Optional `sha256` still detects accidental change of the committed file.

---

## Patches

- Live under `patches/` (or paths listed in `patches = [...]`).
- Applied **only** by `fetch-deps` at materialize — **never** re-applied in `./build`.
- Dirty `src` **only** from these patches is acceptable; other dirt means the tree is not a clean pin.

---

## RO sources and `requires_writable_src`

Default after `fetch-deps ro`: tree is read-only. Build scripts must create/chmod only the directories they need (e.g. `src/build`, `src/bin`). Prefer upstream’s normal out-of-source layout.

If a library **cannot** build from RO sources:

```toml
requires_writable_src = true
```

fetch-deps then leaves `src` writable after materialize (still a git tree at the pin + patches).

---

## Optional local git accelerator (`GIT_HOME`)

If `GIT_HOME/<lib>` (often `~/git/<lib>`) exists, fetch-deps may attach a **worktree** at `src/` so the full object store stays outside the app tree. Correctness does **not** require `GIT_HOME`; plain clone/fetch of the pin SHA still works (optional `--depth`).

Sandbox helpers, when confining writes, may allow only `$GIT_HOME/<lib>/.git` (or the resolved gitdir for a linked worktree) — not the entire `GIT_HOME`.
