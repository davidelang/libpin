# libpin sandbox: bubblewrap + Landlock

**Write confinement** for pin materialize and build on Linux, used when the system provides it.

## Policy: sandboxing is optional protection

- bubblewrap (`bwrap`) and Landlock are **protections**, not requirements. They stop a pin's materialize and build from writing to the rest of the system; libpin works without them.
- Each one is **used when it is installed and works** on this system. "Works" is checked, not assumed: an installed `bwrap` can still be blocked (for example, unprivileged user namespaces restricted for that account).
- When one is missing or unusable, libpin **reports it loudly, with the reason, and continues** without it. When neither is active it says that pin writes are not confined.
- libpin **never refuses to run** because one is missing, and **never drops one silently**.
- `--no-bwrap` / `--no-landlock` (or `LIBPIN_NO_BWRAP=1` / `LIBPIN_NO_LANDLOCK=1`) are deliberate off switches, reported as "disabled"; nobody needs them just because a tool is missing.
- Availability is decided once per run by the entry point (`fetch-deps`, or `libpin-sandbox` when run directly). The low-level helpers `libpin-bwrap` and `libpin-landlock` run only after that decision, so a failure inside them (for example, a Landlock ruleset that will not apply after `--status` said available) is a real fault and stops the run.

**Implementation status (remove when done):** as of 2026-10-24 the kit still exits when `bwrap` or Landlock is missing, and parts of this document and the other docs still describe that. They are being brought in line with this policy.

This document covers capabilities, composition, modes, environment variables, and limits.

---

## Design goals

1. **Harden execution of retrieved trees** — especially untrusted or large third-party sources — so a buggy/malicious build cannot casually rewrite the rest of the app tree or a host clone under `GIT_HOME`.
2. **Keep toolchains working** — JDKs, SDKs, compilers, Docker clients must still **read and execute** host tools and libraries.
3. **Optional, never silent** — see [Policy](#policy-sandboxing-is-optional-protection): used when available, reported when not, the run continues.
4. **Single-level outer jail** — nested bubblewrap user namespaces fail; Landlock **stacks**. Nesting is detected with a write probe, not by reading `LIBPIN_SANDBOX`.

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
   outer            │  libpin-bwrap                       │
                    │  • --ro-bind / /                    │
                    │  • --tmpfs /tmp, /var/tmp           │
                    │  • --ro-bind CWD, kit, GIT_HOME     │
                    │  • --bind <RW hole> <RW hole>       │
                    │  • sets LIBPIN_SANDBOX=<mode>       │
                    └─────────────────┬───────────────────┘
                                      │
                    ┌─────────────────▼───────────────────┐
   inner            │  libpin-landlock                    │
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
| **bubblewrap** | Mount namespaces / bind mounts | Visible filesystem is RO except explicit RW binds and tmpfs temps |
| **Landlock** | Kernel LSM ruleset on the process | Even if a path is visible and otherwise writable, **mutation** is denied unless under an allowed path |

**Order:** bwrap outer → Landlock inner.

**Why:** Landlock is stackable and survives across exec; nested bwrap is avoided by probing whether a write outside the hole already fails.

Host clones are **read-only**. There is no `LIBPIN_HOST_GIT` RW bind and no `resolve_host_git`. `--ro-bind / /` plus `--bind third_party/<lib>` is the write surface; `GIT_HOME` is restored read-only after tmpfs `/tmp` so host clones stay visible for `git clone` without being writable.

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
| `get-artifacts` | **none** | May write `app/…` under the repo root |

get-artifacts does not sandbox. Destinations must still `realpath` inside the repo root.

---

## Nest detection (write probe)

`LIBPIN_SANDBOX` **alone never skips** sandboxing. Confinement is detected with a write at a unique path **outside** the current mode’s writable hole. This redirect is a deliberate test, not a swallow; it is the only allowed `2>/dev/null` in the kit:

```bash
probe="$PARENT/.libpin-probe.$$.$RANDOM"
if printf x >"$probe" 2>/dev/null; then
    rm -f "$probe"        # set -e: fails loudly if it can't be removed
    apply sandbox
else
    already confined; skip nesting
fi
```

Do not create the file with `mktemp` first: `mktemp` itself would fail inside the sandbox. `--no-bwrap --no-landlock` skip both the probe and the sandbox.

---

## bubblewrap (`libpin-bwrap`)

### Install / detect

```bash
sudo apt install bubblewrap   # Debian/Ubuntu: package provides `bwrap`
command -v bwrap
bwrap --version
```

If `bwrap` is missing, `libpin-bwrap` **exits 1** with `pass --no-bwrap --no-landlock to run unsandboxed`. `LIBPIN_NO_BWRAP=1` skips this helper (exec bare) — fetch-deps still requires `--no-landlock` as well unless landlock is also disabled.

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
  --ro-bind $CWD $CWD            # restore if tmpfs hid it
  --ro-bind $TP_ROOT $TP_ROOT
  --ro-bind $GIT_HOME $GIT_HOME  # when set; always read-only
  --bind <RW_DIR> <RW_DIR>       # mode-specific hole
  [--bind docker.sock …]         # if present (Docker client → host daemon)
  [--bind $XDG_RUNTIME_DIR …]
  -- command…
```

| Feature | Behavior |
|---------|----------|
| RO root | Entire host FS mounted read-only |
| RW hole | Only the mode path (lib / src / artifact / third_party) is `--bind` (read-write) |
| tmpfs temps | `/tmp` and `/var/tmp` are empty writable temps inside the jail |
| Restore | CWD, kit root, and `GIT_HOME` are re-bound read-only after tmpfs (tests and hosts under `/tmp` stay visible) |
| Network | Shared (`--share-net`) so HTTPS clones still work when no host exists |
| Nesting | Write probe in `libpin-sandbox`; `LIBPIN_SANDBOX` is informational |
| Host git | **No RW bind.** `GIT_HOME` is read-only when set |
| Docker | Binds `docker.sock` when present so builds that shell out to Docker keep working |
| Disable | `LIBPIN_NO_BWRAP=1` or `--no-bwrap` |

### Limitations (bwrap)

- Requires user namespaces (or setuid bwrap, depending on distro policy). Some hardened hosts restrict unprivileged user namespaces.
- Does **not** replace Landlock: a process that escapes via a writable hole still has that hole; Landlock further restricts mutation even on mounts that appear RW if the hole is too wide (e.g. whole `lib/` when only `src/` should mutate for builds).
- Nested bwrap fails — libpin never nests intentionally.
- `--tmpfs /tmp` hides host paths under `/tmp` until they are restored (CWD, kit, `GIT_HOME`).

---

## Landlock (`libpin-landlock`)

### What Landlock is

[Landlock](https://docs.kernel.org/userspace-api/landlock.html) is a Linux Security Module that lets an unprivileged process restrict **itself** with a ruleset. Once restricted, the process (and children) can only use allowed access rights on allowed path trees.

### Install / detect

No userspace package for the LSM itself — you need a kernel built with Landlock and the LSM enabled.

```bash
./kit/libpin-landlock --status
# available abi=8
# or: unavailable  (exit 1)
```

Also check:

```bash
zcat /proc/config.gz | grep LANDLOCK
# CONFIG_SECURITY_LANDLOCK=y
grep -i landlock /sys/kernel/security/lsm
```

Python 3 + ctypes (stdlib) is enough; no extra Python Landlock package. Shebang is `#!/usr/bin/python3` so an empty `PATH` inside bwrap still finds the interpreter.

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

Builds need temp files and `> /dev/null`; the bound remains “not the app tree outside the pin hole.” `/tmp` being writable in Landlock does not make a host clone writable: bwrap’s read-only bind of `GIT_HOME` still applies.

### Unavailable / apply failure

If Landlock is unavailable or applying the ruleset fails, `libpin-landlock` **exits 1** with `pass --no-bwrap --no-landlock to run unsandboxed`. It does not exec the command bare.

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
| Kernel age | Needs Landlock-capable kernel; older kernels → error unless `--no-landlock` |
| Composition | Stacks under bwrap; can also run Landlock-only if bwrap is disabled |
| `get-artifacts` | Off (destinations may be `app/…`) |

---

## Environment variables (summary)

| Variable | Effect |
|----------|--------|
| `LIBPIN_NO_BWRAP=1` | Skip bubblewrap |
| `LIBPIN_NO_LANDLOCK=1` | Skip Landlock |
| `LIBPIN_SANDBOX=<mode>` | Informational (set by bwrap). **Does not skip** sandboxing |
| `LIBPIN_INSIDE=1` | Set by fetch-deps on re-entry; fetch-deps then passes `--no-bwrap` so bwrap does not nest; Landlock may still stack |
| `LIBPIN_LANDLOCK=1` | Set by landlock after successful restrict |
| `LIBPIN_BWRAP_DEBUG=1` | Print bwrap argv |
| `LIBPIN_LANDLOCK_DEBUG=1` | Print allow paths |
| `GIT_HOME` | Host clone root; bound read-only inside bwrap when set |

---

## Manual invocation

```bash
# Status
./libpin-landlock --status

# Run a command with src-only mutation for library "example"
./libpin-sandbox --mode src --lib example -- \
  bash -c 'echo ok > example/src/build/probe.txt'

# Expect failure writing outside the hole
./libpin-sandbox --mode src --lib example -- \
  bash -c 'echo bad > example/../should-fail.txt'
```

Landlock alone (no bwrap):

```bash
LIBPIN_NO_BWRAP=1 ./libpin-sandbox --mode lib --lib example -- touch example/status.local
```

bwrap alone:

```bash
LIBPIN_NO_LANDLOCK=1 ./libpin-sandbox --mode lib --lib example -- touch example/status.local
```

Fully unsandboxed:

```bash
# fetch-deps / get-artifacts:
./fetch-deps --no-bwrap --no-landlock ro example
# helpers (env only; libpin-sandbox does not take those flags):
LIBPIN_NO_BWRAP=1 LIBPIN_NO_LANDLOCK=1 ./libpin-sandbox --mode lib --lib example -- true
```

---

## Security expectations (honest)

libpin’s sandbox is **hardening for pin tooling**, not a multi-tenant VM boundary.

**Good at:**

- Stopping accidental `rm -rf` / write spray into the rest of the monorepo during materialize/build
- Denying writes into host clones under `GIT_HOME` (those trees are typically owned by a user other than the agent)
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

Missing bwrap or Landlock is an error with the same unsandboxed hint. Pass `--no-bwrap --no-landlock` on those hosts. Pin materialize and build remain the source of truth for correctness.
