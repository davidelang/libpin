# libpin sandbox: bubblewrap + Landlock

Optional **write confinement** for pin materialize and build on Linux. Pin semantics are unchanged when tools are missing: **unsandboxed, still correct**.

This document covers capabilities, composition, modes, environment variables, and limits.

---

## Design goals

1. **Harden execution of retrieved trees** — especially untrusted or large third-party sources — so a buggy/malicious build cannot casually rewrite the rest of the app tree.
2. **Keep toolchains working** — JDKs, SDKs, compilers, Docker clients must still **read and execute** host tools and libraries.
3. **Optional and soft-fail** — no hard dependency on kernel LSM or `bwrap` for day-to-day correctness.
4. **Single-level outer jail** — nested bubblewrap user namespaces fail; Landlock **stacks**.

Primary threat model for Landlock in libpin: **mutation** (write/create/remove/truncate/refer) outside the allowed surface. It is **not** a full confidentiality sandbox (reads stay open by design).

---

## Architecture

```text
                    ┌─────────────────────────────────────┐
  host process      │  fetch-deps / build / …             │
                    └─────────────────┬───────────────────┘
                                      │
                    libpin-sandbox    │
                                      ▼
                    ┌─────────────────────────────────────┐
   outer (optional) │  libpin-bwrap                       │
                    │  • --ro-bind / /                    │
                    │  • --bind <RW hole> <RW hole>       │
                    │  • tmpfs /tmp, /var/tmp             │
                    │  • sets LIBPIN_SANDBOX=<mode>       │
                    └─────────────────┬───────────────────┘
                                      │
                    ┌─────────────────▼───────────────────┐
   inner (optional) │  libpin-landlock                    │
                    │  • handles mutation FS rights only  │
                    │  • path_beneath allow-list          │
                    │  • always + /tmp, /var/tmp, /dev/*  │
                    └─────────────────┬───────────────────┘
                                      │
                                      ▼
                                 user command
```

| Layer | Mechanism | What it constrains |
|-------|-----------|--------------------|
| **bubblewrap** | Mount namespaces / bind mounts | Visible filesystem is RO except explicit RW binds |
| **Landlock** | Kernel LSM ruleset on the process | Even if a path is visible and otherwise writable, **mutation** is denied unless under an allowed path |

**Order:** bwrap outer → Landlock inner.  
**Why:** Landlock is stackable and survives across exec; nested bwrap is avoided via `LIBPIN_SANDBOX`.

Entry point: `libpin-sandbox --mode MODE [--lib NAME] -- command…`

---

## Modes (write surfaces)

Modes are shared by bwrap, Landlock, and `libpin-sandbox`.

| Mode | Used for | Mutation allowed under |
|------|----------|-------------------------|
| `third_party` | rare bulk ops | `third_party/` (the kit root) |
| `lib` | materialize, `status.local`, `rw` | `third_party/<lib>/` |
| `src` | patches, pin `./build` | `third_party/<lib>/src/` |
| `artifact` | optional get-artifacts | `third_party/<lib>/artifact/` |

### When fetch-deps applies which mode

| Step | Mode | Notes |
|------|------|--------|
| Materialize + write `status.local` | `lib` | Need to create `src/`, write pin metadata under the lib dir |
| Apply patches | `src` | Only the source tree |
| Run `build[]` | `src` | Build products under `src/…` |
| `get-artifacts` | **none by default** | May write `app/…`; opt-in sandbox below |

### get-artifacts and sandbox

Collect is **our** copy of already-built products (not executing retrieved build systems). Default: **no** sandbox so destinations like `app/src/main/jniLibs/…` work.

Opt-in (pin-local artifact only):

```bash
LIBPIN_GET_ARTIFACTS_SANDBOX=1 ./get-artifacts mylib
```

That re-enters with `mode=artifact`. Paths outside `third_party/<lib>/artifact/` will fail under confinement — use without sandbox for `app/…` rows.

---

## bubblewrap (`libpin-bwrap`)

### Install / detect

```bash
sudo apt install bubblewrap   # Debian/Ubuntu: package provides `bwrap`
command -v bwrap
bwrap --version
```

If `bwrap` is missing, `libpin-bwrap` **execs the command bare** (debug message if `LIBPIN_BWRAP_DEBUG=1`).

### What it does

Typical argv (simplified):

```text
bwrap
  --ro-bind / /
  --dev /dev
  --proc /proc
  --tmpfs /tmp
  --tmpfs /var/tmp
  --share-net
  --die-with-parent
  --chdir $CWD
  --bind <RW_DIR> <RW_DIR>     # mode-specific hole
  [--bind $LIBPIN_HOST_GIT …]  # linked worktree .git only
  [--bind docker.sock …]       # if present (Docker client → host daemon)
  [--bind $XDG_RUNTIME_DIR …]
  -- command…
```

| Feature | Behavior |
|---------|----------|
| RO root | Entire host FS mounted read-only |
| RW hole | Only the mode path (lib / src / artifact / third_party) is `--bind` (read-write) |
| tmpfs temps | `/tmp` and `/var/tmp` are empty writable temps inside the jail |
| Network | Shared (`--share-net`) so fetches/clones still work |
| Nesting | If `LIBPIN_SANDBOX` is already set → skip bwrap (no nest) |
| Host git | Optional `LIBPIN_HOST_GIT` — **only** that lib’s `.git` (or resolved gitdir), never whole `GIT_HOME` |
| Docker | Binds `docker.sock` when present so builds that shell out to Docker keep working |
| Disable | `LIBPIN_NO_BWRAP=1` or `--no-bwrap` |

### Limitations (bwrap)

- Requires user namespaces (or setuid bwrap, depending on distro policy). Some hardened hosts restrict unprivileged user namespaces.
- Does **not** replace Landlock: a process that escapes via a writable hole still has that hole; Landlock further restricts mutation even on mounts that appear RW if the hole is too wide (e.g. whole `lib/` when only `src/` should mutate for builds).
- Nested bwrap fails — libpin never nests intentionally.

---

## Landlock (`libpin-landlock`)

### What Landlock is

[Landlock](https://docs.kernel.org/userspace-api/landlock.html) is a Linux Security Module that lets an unprivileged process restrict **itself** with a ruleset. Once restricted, the process (and children) can only use allowed access rights on allowed path trees.

### Install / detect

No userspace package for the LSM itself — you need a kernel built with Landlock and the LSM enabled.

```bash
./kit/libpin-landlock --status
# available abi=8
# or: unavailable
```

Also check:

```bash
zcat /proc/config.gz 2>/dev/null | grep LANDLOCK || true
# CONFIG_SECURITY_LANDLOCK=y
grep -i landlock /sys/kernel/security/lsm 2>/dev/null || true
```

Python 3 + ctypes (stdlib) is enough; no extra Python Landlock package.

### What libpin handles

libpin **handles only mutation** filesystem rights:

| Right | Handled? | Effect if not allowed |
|-------|----------|------------------------|
| Write file, truncate | yes | Denied outside allow-list |
| Create (reg/dir/sock/fifo/…), remove, make symlink | yes | Denied |
| Refer (link/rename across) | yes | Denied |
| **Read file / read dir** | **no** (unhandled) | Always allowed |
| **Execute** | **no** (unhandled) | Always allowed |

**Why mutation-only:** pin builds need the entire host toolchain (compilers, JDK, NDK, system libs). Restricting read/exec would require binding every possible tool path into the ruleset. Mutation confinement is the high-value, low-friction layer.

### Always-granted mutation paths

When any ruleset is applied, libpin also allows mutation under:

- `TMPDIR` / `TEMP` / `TMP` (if set and existing)
- `/tmp`, `/var/tmp`
- Essential devices as **files**: `/dev/null`, `/dev/zero`, `/dev/full`, `/dev/urandom`, `/dev/random`, `/dev/tty`

Builds need temp files and `> /dev/null`; corruption bound remains “not the app tree outside the pin hole.”

### Host git allow

For linked worktrees, git must update the object store / worktree registry under the host clone’s `.git`. `libpin-sandbox` resolves `GIT_HOME/<lib>/.git` (or gitdir from a gitfile, stripping `/worktrees/…`) and passes it as an extra Landlock path and bwrap RW bind — **narrow**, not whole `GIT_HOME`.

### Soft-fail

If ruleset creation or restrict fails, libpin prints a warning and **execs bare** (same spirit as missing bwrap). Correctness over hard fail on sandbox.

### Disable

```bash
LIBPIN_NO_LANDLOCK=1
# or fetch-deps --no-landlock
```

### Limitations (Landlock)

| Topic | Detail |
|-------|--------|
| Confidentiality | Reads are unrestricted — secrets on the host remain readable |
| Network / IPC | Not covered by this helper |
| ABI / arch | Syscall numbers wired for x86_64 and aarch64 (common modern NRs 444–446) |
| Kernel age | Needs Landlock-capable kernel; older kernels → unavailable → bare exec |
| Composition | Stacks under bwrap; can also run Landlock-only if bwrap is disabled/missing |
| `get-artifacts` | Off by default (see modes) |

---

## Environment variables (summary)

| Variable | Effect |
|----------|--------|
| `LIBPIN_NO_BWRAP=1` | Skip bubblewrap |
| `LIBPIN_NO_LANDLOCK=1` | Skip Landlock |
| `LIBPIN_SANDBOX=<mode>` | Already inside bwrap — do not nest |
| `LIBPIN_LANDLOCK=1` | Set by landlock after successful restrict |
| `LIBPIN_BWRAP_DEBUG=1` | Print bwrap argv / skip reasons |
| `LIBPIN_LANDLOCK_DEBUG=1` | Print allow paths / skip reasons |
| `LIBPIN_HOST_GIT=/path` | Extra RW for linked worktree `.git` |
| `GIT_HOME` | Used to **resolve** host git path; not wholly allowed |
| `LIBPIN_GET_ARTIFACTS_SANDBOX=1` | Confine collect to `artifact/` mode |

---

## Manual invocation

```bash
# Status
./libpin-landlock --status

# Run a command with src-only mutation for library "example"
./libpin-sandbox --mode src --lib example -- \
  bash -c 'echo ok > example/src/build/probe.txt'

# Expect failure writing outside src (when Landlock or bwrap active)
./libpin-sandbox --mode src --lib example -- \
  bash -c 'echo bad > example/../should-fail.txt'   # may fail depending on layer
```

Landlock alone (no bwrap):

```bash
LIBPIN_NO_BWRAP=1 ./libpin-sandbox --mode lib --lib example -- touch example/status.local
```

bwrap alone:

```bash
LIBPIN_NO_LANDLOCK=1 ./libpin-sandbox --mode lib --lib example -- touch example/status.local
```

---

## Security expectations (honest)

libpin’s sandbox is **hardening for pin tooling**, not a multi-tenant VM boundary.

**Good at:**

- Stopping accidental `rm -rf` / write spray into the rest of the monorepo during materialize/build
- Reducing blast radius of a compromised or buggy upstream build script against the app tree
- Making “what can this step write?” explicit in code (modes)

**Not a substitute for:**

- Reviewing patches and Docker images you run
- Network isolation (bwrap currently `--share-net`)
- Seccomp filters, full rootless containers, or VM isolation for untrusted code
- Preventing read of secrets on the same host (Landlock mutation-only policy)

For untrusted CI of adversarial source trees, combine with stronger isolation (containers, VMs, dedicated runners) and treat libpin as the **in-process write policy** layer.

---

## Non-Linux

Both helpers detect platform / tool availability and run the command unsandboxed. Pin materialize and build remain the source of truth for correctness.
