# libpin hardening plan (2026-10-24)

Instructions for Grok Build. Agreed with David on 2026-10-24.

## Where to work
- Upstream is this repo, `~/git/libpin`; scripts are in `kit/` (fetch-deps, get-artifacts, libpin-sandbox, libpin-bwrap, libpin-landlock).
- Commit in this repo after each phase. Do not push. Do not publish to orchestration-example or any project; David will say when.
- Do not touch the untracked `docs/PLAN_IMAGE_PACKAGE_PINS.md` or `publish-to-github.sh`. The image-pin plan is separate work.

## Principles (non-negotiable)
- Fail loudly and exit with a clear message. No `|| true`, `2>/dev/null`, `|| echo default`, or warn-and-skip that hides a failure. Run orchestration-example's `tools/audit-swallow` against `kit/`.
- No fallbacks: one defined path per operation; if it is missing or wrong, fail and say why.
- No locks. Fix root causes; no stacked special cases.
- No sudo. Never change ownership or modes of repos you don't own; report needed permission changes for David with exact commands.
- Pins without `git_sha` may follow their tracked branch; partial shas are accepted. Resolve to a full commit; fail if ambiguous or missing.
- Python >= 3.11 (tomllib only, no tomli). curl only (no wget).

## Phases (each with tests, each committed)
1. **Merge (step 0).** `kit/` is behind orchestration-example's `third_party/`. Take orchestration-example's fetch-deps/get-artifacts (--record, upgrade restore, swallow cleanups) as the base. Add host_repo from VehicleExpenses-automated agent-1 commit `42450702`. Keep git_repo_error / real git stderr from `e21ad52d`, but NOT its `--shared` (alternates) clone.
2. **Host read-only** (see below).
3. **Fail-loud** (code fixes below).
4. **Artifacts** (below).
5. **Features** (below).
6. **Docs**: PIN_FORMAT, SANDBOX, GUIDE, QUICKSTART, README. They currently describe worktrees, an optional sandbox, optional sha256, default pick = newest, and tomli.

## Phase 2: the host repo is read-only
Agents run as ai-* users; host repos under git_home (e.g. `/home/dlang/git/paddle`, dlang:dlang 775) belong to David. Writing into a host `.git` fails with Permission denied and breaks the rule that a lib being processed writes only inside its own `third_party/<pin>/`.

### Materialize decision tree (ro, rw, upgrade all use it)
```
host = host_repo (name under GIT_HOME, or absolute path) else GIT_HOME/<name>
absolute host path under GIT_HOME             -> error (use the name)
GIT_HOME/<name> exists but is not a git repo  -> error
leftover smudge token (@@GIT_HOME@@)          -> error
if host_repo set OR host is a git repo:
    require read access (else print the chmod/setfacl David would run)
    resolve sha (partial -> unique full sha, else error)
    reuse src if it is a standalone clone (toplevel == src, no alternates,
      not a linked worktree) that has the commit; fetch a missing commit from host into it
    otherwise: clone --no-hardlinks --no-checkout host src; checkout --detach sha
    never network
elif git_https:            that only
elif source = "seed-src":  that only
else: error
```

### Details
- One shared resolve-host helper, used by fetch-deps (local_repo_for, refresh, ro, rw, upgrade, remove_linked_worktree_src) and anywhere else a host is needed.
- `host_repo`: optional libpin.toml key, defaults to the pin name. A repo name under git_home, or an absolute path outside git_home.
- `-c safe.directory=<resolved absolute host path>` on every git call against the host (clone, fetch, cat-file, rev-parse, show, outdated). Never on the agent-owned src, never `*`, no global config edits.
- Show git's real stderr on any host failure (e.g. "detected dubious ownership"), never a rewritten "not a git repo".
- A linked-worktree or `--shared` src is replaced with `rm -rf src` plus a fresh clone. Print `git -C <host> worktree prune` for David; leftover host metadata is acceptable until he runs it.
- At clone time: origin = git_https (when present); add remote `host` = resolved host path.
- rw and upgrade: same clone, then `checkout -B <branch>` in src. Print for David: `git -C <src> push host HEAD:refs/heads/<branch>`. Agents never push to the host.
- upgrade: branches exist only in src. On success, delete the branch and detach at the new pin. On failure, keep src and its branch for debugging. Write status.local only after a successful patch.
- libpin-sandbox: remove host `.git` write access entirely (drop LIBPIN_HOST_GIT and resolve_host_git). bwrap `--ro-bind / /` plus `--bind third_party/<lib>` is enough; landlock lib mode already denies writes outside the pin dir.
- Sandbox re-entry: the LIBPIN_SANDBOX environment variable alone must never skip sandboxing. Detect confinement with a write probe outside the pin's writable area: probe fails = already confined, skip nesting; probe succeeds = apply bwrap (remove the probe file; fail loudly if it can't be removed).
- Disk: `--no-hardlinks` copies objects per worktree (opencv ~573M each). David has accepted this.

## Phase 3: fail-loud code fixes
1. errexit: `cmd_x || FAILURES=...` disables set -e inside cmd_*. Restructure (e.g. each pin in a subshell with `set -e`). A failed pin aborts that pin only; later names still run; exit non-zero at the end listing every failure.
2. Every path that records a sha (ro, refresh, upgrade, write_pin_sha) first checks `git -C "$src" rev-parse --show-toplevel` == "$src", so the consumer repo's HEAD can never be pinned.
3. Remove swallowed errors: git_https `|| true`; requires_writable_src (use pin_get_opt); status.local `|| echo ro`; `ve_branch || echo unknown`; git calls with 2>/dev/null; chmod `2>/dev/null || true`; artifact rows without `from` (fail).
4. Remove fallback chains: invalid host -> network; host missing commit -> network; smudge token -> network; fetch-by-sha -> fetch-all; https -> ssh -> seed-src; worktree add -> clone; curl -> wget; tomllib -> tomli; offer_mainish_retarget; the master and host/master/.git special cases in refresh.
5. Transport: git_https is the only network transport. git_ssh is recorded metadata the tool never uses. seed-src is used only when declared (`source = "seed-src"`); an empty git_https does not imply it. Update kit/example.
6. Sandbox tools: missing bwrap/landlock is an error everywhere (Linux, non-Linux, CI) with the message "pass --no-bwrap --no-landlock to run unsandboxed". No platform auto-detection.
7. Exact path matches everywhere (no `grep -q "$src"` substring/regex matches; use `worktree list --porcelain` / realpath comparisons).
8. Patches: honor `patches = [...]` order when present, else one sorted list of *.patch and *.diff. Reject paths with `..` or a leading `/`. Run patch cleanup inside the sandbox. Apply patches for file pins (or fail if a file pin has patches).
9. write_pin_sha: top-level git_sha only (before the first table), escape values, temp file + rename, no chgrp.
10. upgrade reproducibility check: build twice from a clean state (fresh clone, or git clean -xfd plus build dirs), not an incremental rebuild.
11. Remove project coupling: VE_ROOT, ve_branch, chgrp ai-code / chmod 664 (group bits are left to umask/ACLs), hard-coded git_home (must come from configuration/flag; fail if unset). `--worktree-search`: report what it does and remove it if it is a project-specific special case.

## Phase 4: artifacts
1. sha256 is required. The only placeholder is 64 zeros, which --record replaces. A missing sha256 key is an error except under --record, which inserts the line into that [[artifact]] table (temp file + rename). Empty or "TBD" are errors.
2. Glob matching zero files is a failure (remove the basename `find` fallback). Omitted pick -> exactly one match required. `pick = "newest"` stays valid when written explicitly; unknown pick values are errors. kit/example sets `pick = "newest"`.
3. Drop the `artifacts`/`from_src` aliases; record_artifact_shas verifies its row count equals the parsed count.
4. get-artifacts resolve_dest: destinations must resolve inside REPO_ROOT (realpath). Relative app/... promote rows stay valid.
5. Replace the hard-coded skip lists (rclone|paddle|example in fetch-deps, example in get-artifacts) with a pin key `default = false`, honored the same way in both scripts.

## Phase 5: features
A. `fetch-deps check` (new command) covers: host_repo validation; git_home leak warning (a committed libpin.toml containing the expanded git_home path means the clean filter didn't run; also offer it as a pre-commit hook); depends; moved tags.
B. `depends = ["<pin>"]`: read `git show <pin-sha>:third_party/<dep>/libpin.toml` from the host and fail if its git_sha (resolved to full) differs from this tree's pin for that dep, naming both.
C. `fetch-deps outdated`: compare each pin with its upstream (host repo, or track_branch on the network transport). Store the tip seen at the last check in status.local; report separately (a) upstream moved since the last check and (b) still behind with no new movement. Read-only apart from status.local.
D. track_branch: look it up as refs/tags/X and refs/heads/X in the host. Both exist -> error. Branch -> refresh follows that branch. Tag -> refresh only verifies the tag still resolves to the pinned sha (fail "tag moved"); changing it requires `upgrade --ref`.
E. Submodules/LFS: when materializing, fail loudly if the source has a .gitmodules file or contains Git LFS pointer files.
F. Companion version: one `kit/VERSION` file. fetch-deps, get-artifacts and libpin-sandbox each refuse to run on a mismatch, including when invoked alone. They are always published as one set.

## Out of scope
Toolchain provenance for reproducible=false pins; a shared large-file cache; build variants; offline mode beyond git_home; upgrade dry run/changelog.

## Tests
In `kit/tests/`, seeded from orchestration-example `tools/test-fetch-deps-record`, using throwaway --git-home fixtures. Cover: errexit abort with later pins still running; show-toplevel guard; zero glob matches; ambiguous short sha; no network when a host exists; non-git GIT_HOME/<name>; smudge token; host_repo resolution and absolute-inside-git_home rejection; linked-worktree replacement message; src reuse; sandbox denies writes to host .git; LIBPIN_SANDBOX alone does not skip the sandbox; missing sandbox tools; required sha256; --record filling a placeholder and inserting a new row; patch path rejection and patch order; default = false; depends mismatch; outdated reporting; moved tag; tag+branch ambiguity; submodule/LFS refusal; companion version mismatch; git_home leak warning. The host-owned-by-another-user case: a documented manual probe plus safe.directory unit coverage if a chown fixture is impossible without root.

## Report back
Commits per phase; each item done or not with the reason; test results; audit-swallow result; any permission changes David must make (exact commands); and the consumer impact for VehicleExpenses-automated, liveimap, torque-ford-gas-tracking, extractmail and remotetable, at least:

| Pin / tree | Change |
|---|---|
| paddle-opt | host_repo = "paddle" already; its 64-zero sha256 must be filled by --record |
| extractmail | add depends = ["remotetable"]; rw commits stay in src until David pushes |
| opencv | track_branch = "4.10.0" becomes a tag check; ro copies ~573M of objects per worktree |
| rclone / paddle | need default = false to keep today's skip; without it they join the default set |
| example | needs an artifact sha256 (or --record) and pick = "newest" |
| pins with both URLs | git_ssh no longer used; git_https only |
| all projects | fetch-deps without --no-bwrap/--no-landlock fails if sandbox tools are missing |
| leftover linked worktrees | David runs `git -C <host> worktree prune` once per host |
