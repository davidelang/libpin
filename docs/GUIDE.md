# libpin guide

End-to-end workflows, actor responsibilities, profiles, and how to integrate the kit into a consumer repository.

Also see: [QUICKSTART](QUICKSTART.md) · [PIN_FORMAT](PIN_FORMAT.md) · [SANDBOX](SANDBOX.md) · [CASE_STUDY](CASE_STUDY_VEHICLEEXPENSES.md)

---

## 1. Problem statement

Prebuilt native/Java binaries without a clear **source SHA + recipe + artifact** path fail third-party review and make “why is this `.so` different?” unanswerable. Custom flags, patches, and Docker stacks must be **reproducible as a process**, even when the binary is not bit-for-bit reproducible.

Ownership (“we maintain this GitHub repo” vs “pure upstream”) does **not** change the tree. Co-developing a library next to the app is a **method**, not a second layout.

---

## 2. One layout for every library

```text
third_party/
  README.md                 # optional; kit ships tools at this level
  fetch-deps
  get-artifacts
  libpin-sandbox | libpin-bwrap | libpin-landlock
  example/                  # hello-world pin
  <lib>/
    libpin.toml
    SOURCE.md               # human narrative (profiles, gotchas)
    patches/                # optional; only applied by fetch-deps
    build                   # executable; may invoke scripts/
    scripts/
    src/                    # git tree @ pin and/or [[source]] files
    artifact/               # stable names committed for consumers
    status.local            # gitignored — ro/rw mode
```

| Path | Role |
|------|------|
| `libpin.toml` | Pin identity and collection rules |
| `src/` | Authoritative **source** after materialize |
| `src/build/`, `src/bin/` (or upstream-equivalent) | Scratch / build outputs; **not** the app pin |
| `artifact/` | What the app commits and links; present after clone without `src` |
| `patches/` | Diffs applied **only** at materialize |

---

## 3. Workflows

### Audit / reproduce (default)

```bash
./third_party/fetch-deps ro <lib>      # checkout pin, apply patches, chmod sources RO
./third_party/fetch-deps build <lib>   # run build script(s), get-artifacts → artifact/
```

### Iterate a build (sources already there)

```bash
# edit scripts or flags; re-run build
./third_party/<lib>/build
./third_party/get-artifacts <lib>
```

### Co-develop library + app

```bash
./third_party/fetch-deps rw <lib>      # writable branch (often named like the app branch)
# edit under third_party/<lib>/src (or host worktree)
./third_party/fetch-deps build <lib>
# bump pin when ready: libpin.toml + artifact/ + commit on the app branch
```

### Materialize-only (file pins, pure sources)

```toml
build = []
```

```bash
./third_party/fetch-deps ro models-pack
# no build; consumers read third_party/models-pack/src/…
```

### Local full clone (`GIT_HOME`)

Optional. If `~/git/<lib>` (or `GIT_HOME/<lib>`) exists, fetch-deps may materialize `src` as a **worktree** or fetch objects from that host so the app tree does not hold a full object store. **Without GIT_HOME**, clone/fetch of the pin SHA still works (optional `--depth`).

---

## 4. Responsibilities

| Actor | Does | Does not |
|-------|------|----------|
| **fetch-deps** | Materialize `src` @ `git_sha` and/or `[[source]]`; apply `patches/`; set RO (unless lib requires RW); run `build[]`; call **get-artifacts** | Invent build flags; leave app binaries only under `src` |
| **build script(s)** | Given already-patched tree: make build/output dirs writable; compile; write products under `src/…` | Apply patches; write final pin names under `artifact/` (get-artifacts is normative) |
| **get-artifacts** | Read libpin.toml; resolve `from` globs; **pick** if needed; copy to each `path`; optional `sha256` check | Materialize sources; execute pin build |

---

## 5. Commands reference

```text
./third_party/fetch-deps [options] [NAME…]
./third_party/fetch-deps <command> [options] [NAME…]

Commands:
  (default) | ro   Read-only pin (git @ git_sha and/or [[source]]; then RO)
  rw               Writable branch (git) / writable src (files)
  status           Show mode / HEAD / pin / dirty (-v / -vv)
  refresh          Advance pin SHA from library master tip + materialize ro (git)
  upgrade NAME --ref REF   try ref, build, collect, update libpin.toml
  build            Run build[] from libpin.toml, then get-artifacts

Options (common):
  --allow-ssh          Permit git@ for *git* transport only
  --git-home DIR       Override GIT_HOME
  --branch NAME        rw branch name
  --depth N            optional shallow clone (not default)
  --no-bwrap           Disable bubblewrap
  --no-landlock        Disable Landlock
```

```text
./third_party/get-artifacts [NAME…]
  # default NAME set: every pin with libpin.toml except "example"
  --no-bwrap / --no-landlock
  LIBPIN_GET_ARTIFACTS_SANDBOX=1  # artifact mode only
```

---

## 6. Profiles (same contract, different stories)

| Profile | Example | Materialize | Build |
|---------|---------|-------------|--------|
| Options-only | opencv | pin SHA | Script + flags (ABIs, modules) |
| Patch + wrap | rclone | pin + patches | Script (± Docker) → mobile lib |
| Docker + models | paddle | pin (fork commit) | Containers, multi-ABI, tailor |
| File pack | paddle-models | `[[source]]` + sha256 | `build = []` |
| Active co-dev | remotetable / extractmail | `ro` for audit; `rw` while developing | Gradle AAR; often `reproducible=true` |

---

## 7. Integrating the kit

### Vendor copy (recommended for standalone consumers)

```bash
# From consumer repo root
mkdir -p third_party
rsync -a /path/to/libpin/kit/ third_party/ --exclude example/src --exclude '*/status.local'
# Keep or drop kit/example and kit/files-pin as smoke tests
git add third_party/
```

Until libpin is published as a package, **copy** the scripts (not a live nested git dependency of the tools themselves). Pins may still be git checkouts under `third_party/<lib>/src`.

### Nested consumer (library that itself has third_party)

Same layout under the library’s tree. extractmail-style: vendored copy of fetch-deps/get-artifacts/libpin-* plus its own pins. See case study.

### Artifact destinations into the app

```toml
[[artifact]]
path = "app/src/main/jniLibs/arm64-v8a/libfoo.so"
from = "src/bin/arm64-v8a/libfoo.so"
sha256 = "…"
```

`get-artifacts` resolves `app/…` under the **repo root** (parent of `third_party/`).

---

## 8. Do not

- Apply patches in the **build** script (fetch-deps already did).
- Leave app-consumed binaries **only** under `src/` (they vanish without materialize).
- Treat `~/git/...` as the pin if `src/` was never materialized.
- `git add` a full non-submodule dump of library sources into the app repo.
- Use SSH for `[[source]]` URLs (never; use HTTPS / file / seed).
- Expect bit-identical SO files when `reproducible = false` (process still must be documented).

---

## 9. Testing the toolkit itself

From this repo’s `kit/`:

```bash
./fetch-deps ro example files-pin
./fetch-deps build example
test -s example/artifact/hello.bin
test -f files-pin/src/hello.txt
./libpin-landlock --status || true
LIBPIN_BWRAP_DEBUG=1 LIBPIN_LANDLOCK_DEBUG=1 ./fetch-deps status -v
```

---

## 10. Future notes

- `pick: smart` — version-like tiers on filename text before mtime (tracked as optional enhancement).
- Published package / versioned release of the kit (this repo is the extract).
