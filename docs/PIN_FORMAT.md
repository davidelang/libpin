# libpin.toml — pin format reference

`libpin.toml` is the **pin contract**: identity, how to build, and how to collect artifacts. It is **not** machine-specific (no “this laptop’s paths”). Checkout mode (RO/RW) lives in gitignored `status.local`.

Format: **TOML** (no significant indentation). Filename ties to the tooling name *libpin*. Parser: Python ≥ 3.11 `tomllib` only.

Companion kit stamp: `kit/VERSION` must match the `LIBPIN_VERSION` embedded in every kit script. The five scripts plus `VERSION` are published as one set.

---

## Top-level fields

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `name` | string | yes | Library id; directory name under `third_party/` |
| `git_https` | string | for network git pins | HTTPS clone URL (preferred network transport; agents use this first) |
| `git_ssh` | string | optional | SSH clone URL; used when `git_https` is unset |
| `git_sha` | string | for git pins | Locked commit (full SHA preferred; partial SHAs accepted if unique) |
| `git_describe` | string | optional | Human label (tag / describe); updated with `git_sha` on refresh/upgrade |
| `track_branch` | string | optional | Branch **or** tag the pin tracks (see below) |
| `host_repo` | string | optional | Host lookup: a name under `GIT_HOME`, or an absolute path **outside** `GIT_HOME` |
| `source_kind` | string | when not a git pin | `"files"` for `[[source]]` pins; `"seed-src"` for `./seed-src` materialize |
| `default` | bool | optional | `false` omits the pin from the default NAME set of fetch-deps and get-artifacts |
| `depends` | array of strings | optional | Other pin names whose `git_sha` must match at this pin’s tree |
| `reproducible` | bool / string | recommended | `true` \| `false` \| `"unknown"` — bit-identical artifacts expected? |
| `build_time` | string | recommended | t-shirt size (see below) |
| `requires_writable_src` | bool | optional | Default `false`. If `true`, leave `src` writable after materialize |
| `build` | array of strings | optional | Commands run from the pin dir; `[]` = materialize-only |
| `consumer_note` | string | optional | One-line note for humans / agents |
| `patches` | array of strings | optional | Explicit patch order; else one sorted list of `*.patch` and `*.diff` |

A leftover `@@GIT_HOME@@` (or any `@@…@@`) token in `git_home` / `host_repo` is always an error.

### `build_time` values

| Value | Meaning |
|-------|---------|
| `minutes` | Roughly under ~10 minutes |
| `tens_of_minutes` | ~10–60 minutes |
| `few_hours` | ~1–4 hours |
| `tens_of_hours` | Long Docker / full SDK rebuilds |

### Git transport policy

- A local host clone (`GIT_HOME` / `host_repo`) is an **optional offline shortcut**, never mandatory.
- **Network:** `git_https` if set, else `git_ssh`. Agents typically succeed on HTTPS; SSH may need David’s keys.
- If the host shortcut is missing or unreadable, fetch-deps uses the remote URL and prints the `chown` / `chmod` / `setfacl` / `ssh` command David can run.
- File `[[source]]` URLs **never** use SSH (`https://`, `http://`, `file:relative`, `file:///abs` only). curl is the only HTTP client.

### `source_kind`

| Value | Materialize |
|-------|-------------|
| omitted / git | git at `git_sha` (host shortcut if usable, else `git_https`, else `git_ssh`, else seed-src) |
| `"files"` | `[[source]]` rows only (seed or url + sha256) |
| `"seed-src"` | run `./seed-src` in the pin dir; empty `git_https` does **not** imply this |

### `host_repo` and `GIT_HOME`

`host_repo` is **set** only when the key is present in the TOML. The pin name is the `GIT_HOME` lookup key when `host_repo` is omitted, not an implicit `host_repo` value.

| Situation | Result |
|-----------|--------|
| `host_repo` present, name (not absolute), `GIT_HOME` set | shortcut `$GIT_HOME/<name>` if it is a readable git repo |
| `host_repo` present, name, `GIT_HOME` unset | no shortcut; use `git_https` / `git_ssh` |
| `host_repo` present, absolute path under `GIT_HOME` | error (use the name) |
| `host_repo` present, absolute path outside `GIT_HOME` | shortcut if it is a readable git repo; else remote |
| `host_repo` absent, `GIT_HOME` set, `$GIT_HOME/<pin>` is a readable git repo | that shortcut |
| `host_repo` absent, path exists but is not git / not readable | skip shortcut, print why (chown/chmod/setfacl if permissions), use remote |
| `host_repo` absent, `GIT_HOME` unset or path missing | no shortcut; use remote |
| leftover `@@…@@` token | error |

If the shortcut is a readable git repo that has the pin sha, clone from it (`--no-hardlinks`, no network). If it is missing, unreadable, or lacks the commit, use `git_https` or `git_ssh`. An unreadable host prints:

```text
David: chmod a+rX <host> && chmod -R a+rX <host>/.git
or:    setfacl -R -m u:<agent>:rx <host>
or:    chown -R dlang:dlang <host> && chmod -R a+rX <host>
```

An SSH failure prints `ssh -T`, `git clone <git_ssh> <src>`, `chmod` on `~/.ssh`, and an example `GIT_SSH_COMMAND=ssh -i …` for David.

Materialize from a host is `git clone --no-hardlinks --no-checkout` then `checkout --detach <sha>`. Linked worktrees and clones with alternates (`--shared`) are replaced. `origin` is `git_https` or `git_ssh`; remote `host` is the resolved path when the shortcut exists.

`--git-home DIR` overrides the smudged `git_home=` value. Consumers smudge lowercase `git_home=`; the kit does not hard-code a machine path.

### `track_branch`

Looked up as `refs/tags/<name>` and `refs/heads/<name>` on the host shortcut if usable, else via `git ls-remote` on `git_https` / `git_ssh`. Both exist → error.

| Kind | `refresh` | `upgrade --ref` |
|------|-----------|-----------------|
| branch | advances the pin to the branch tip | allowed |
| tag | verifies the tag still resolves to the pinned sha (fail “tag moved”) | required to change the pin |

Pins without `git_sha` may follow `track_branch`. Partial shas are accepted; resolve to a unique full commit or fail.

### `depends`

`depends = ["<pin>"]`. At this pin’s sha, read `third_party/<dep>/libpin.toml` from materialized `src` if present, else `git show <pin-sha>:…` on the host. If neither exists: fail “need host or src”. Fail if that file’s `git_sha` (resolved to full) differs from this tree’s pin for that dep, naming both.

### `default = false`

Omits the pin from fetch-deps and get-artifacts when no NAME arguments are given. Explicit `fetch-deps ro rclone` still runs. Use this for heavy pins that should not join the default set (rclone, paddle, the kit `example`).

---

## Git pin example

```toml
name = "opencv"
git_ssh = "git@github.com:opencv/opencv.git"   # used if git_https is unset
git_https = "https://github.com/opencv/opencv.git"
git_sha = "71d3237a093b60a27601c20e9ee6c3e52154e8b1"
git_describe = "4.10.0"
track_branch = "4.10.0"   # tag: refresh verifies; upgrade --ref to move
host_repo = "opencv"      # optional; omit to look up GIT_HOME/opencv

reproducible = false
build_time = "tens_of_minutes"
requires_writable_src = false
build = ["./build"]
consumer_note = "Android ABIs; 16k pages; slim modules"

[[artifact]]
path = "artifact/jni/arm64-v8a/libopencv_java4.so"
from = "src/bin/arm64-v8a/libopencv_java4.so"
sha256 = "…"

[[artifact]]
path = "app/src/main/jniLibs/arm64-v8a/libopencv_java4.so"
from = "src/bin/arm64-v8a/libopencv_java4.so"
sha256 = "…"
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

File pins with a `patches` key or a `patches/` directory are an error (no `git apply` on a non-git src).

---

## Artifacts: `[[artifact]]`

Each section is independent (same `from` may appear twice with different `path`).

| Field | Required | Meaning |
|-------|----------|---------|
| `path` | yes | Destination (see resolution); must resolve inside the repo root |
| `from` | yes | Source under the pin dir after build (may be a **glob**) |
| `pick` | for multi-match globs | `newest` \| `sort` \| `sort-n`. **Omitted** → exactly one match required |
| `sha256` | yes | Content hash. The only placeholder is 64 zeros, which `--record` replaces. Empty or `"TBD"` are errors. A missing key is an error except under `--record`, which inserts the line |

Aliases `artifacts` / `from_src` are errors.

### `path` resolution

| `path` | Resolved as |
|--------|-------------|
| `artifact/…` or other pin-relative | `third_party/<lib>/<path>` |
| `app/…` | `<repo-root>/app/…` (e.g. Android jniLibs) |
| absolute | only if `realpath` is under the repo root |

### Glob + `pick`

```toml
[[artifact]]
path = "artifact/hello.bin"
from = "src/bin/hello-*.bin"
pick = "newest"
sha256 = "…"
```

Zero glob matches is a failure. If `from` is not a glob, omit `pick` (exactly one file). Table name is singular **`[[artifact]]`**. `pick = "newest"` is valid when written explicitly; it is not a default.

### Reproducible builds

- `reproducible = true` — same pin + patches + scripts expected to yield **bit-for-bit** identical artifacts. `upgrade` builds twice (each after `git clean -xfd` plus removing `src/build` and `src/bin`) and the second must match the recorded sha256.
- `false` / `unknown` — process is still reproducible; bytes may vary (timestamps, NDK, Docker base). Required `sha256` still detects accidental change of the committed file.

`build --record` writes new sha256 values into `libpin.toml` (temp file + rename).

---

## Patches

- Honor `patches = [...]` order when present, else one sorted list of `*.patch` and `*.diff`.
- Reject paths with `..` or a leading `/`.
- Applied **only** by `fetch-deps` at materialize — **never** re-applied in `./build`.
- Dirty `src` **only** from these patches is acceptable; other dirt means the tree is not a clean pin.

---

## RO sources and `requires_writable_src`

Default after `fetch-deps ro`: tree is read-only (`chmod a-w` on files). Directories stay owner-writable. After a build, `src/build` and `src/bin` are re-opened so rebuilds can iterate. Build scripts may chmod only those scratch dirs.

If a library **cannot** build from RO sources:

```toml
requires_writable_src = true
```

fetch-deps then leaves `src` writable after materialize (still a git tree at the pin + patches).

---

## Branch names (rw / upgrade)

| Command | Default branch in `src` | Override |
|---------|-------------------------|----------|
| `rw` | `work` | `--branch NAME` |
| `upgrade` | `upgrade/<ref>` | `--branch NAME` |

Branches exist only in `src`. Agents never push to the host. On success, upgrade deletes the branch and detaches at the new pin. On failure, src and its branch are kept for debugging. Print for David: `git -C <src> push host HEAD:refs/heads/<branch>`.

`status.local` has no `ve_branch` field.

---

## Submodules and Git LFS

Materialize fails if the source has a `.gitmodules` file or contains Git LFS pointer files.

---

## `fetch-deps check` / `outdated`

- **check:** `host_repo` validation; git_home leak warning (a committed `libpin.toml` containing the expanded `GIT_HOME` path means the clean filter did not run; `kit/hooks/pre-commit-git-home-leak` offers the same as a hook); `depends`; moved tags.
- **outdated:** compare each pin with its upstream (host shortcut if usable, else `track_branch` on `git_https` / `git_ssh`). Store the tip seen at the last check in `status.local`; report separately (a) upstream moved since the last check and (b) still behind with no new movement. Read-only apart from `status.local`.
