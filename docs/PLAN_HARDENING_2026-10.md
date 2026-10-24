# libpin hardening plan (2026-10-24)

Instructions for Grok Build. Agreed with David on 2026-10-24.

## Where to work
- Upstream is this repo: `~/git/libpin`, scripts in `kit/` (fetch-deps, get-artifacts, libpin-sandbox, libpin-bwrap, libpin-landlock).
- `kit/` is currently BEHIND the copies in `~/git/orchestration-example/third_party/` (which add `--record`, upgrade sha recording, audit-swallow cleanups). Step 0 brings kit up to date before anything else.
- VehicleExpenses-automated/agent-1 (branch code-review) has local libpin work to merge in: `42450702` (host_repo key) and `e21ad52d` (ro uses a shared clone; real git stderr shown). Read them; merge the ideas, not necessarily the code.
- Commit in this repo. Do not push. Do not publish to orchestration-example or any project; David will say when. Do not touch the untracked `docs/PLAN_IMAGE_PACKAGE_PINS.md` or `publish-to-github.sh`.

## Principles (non-negotiable)
- Fail loudly and exit with a clear message. No `|| true`, `2>/dev/null`, `|| echo default`, or warn-and-skip that hides a failure.
- No fallbacks: one defined path per operation; if missing or wrong, fail and say why.
- No locks. Fix root causes; no stacked special cases.
- No sudo. Never change ownership/modes of repos you don't own; report needed permission changes for David.
- Pins without `git_sha` may follow their tracked branch; partial shas are accepted. Resolve to a full commit; fail if ambiguous or missing.

## Core design change: the host repo is read-only
Agents run as ai-* users; host repos under git_home (e.g. `/home/dlang/git/paddle`, dlang:dlang 775) are owned by David. Writing into a host `.git` (worktree add, branches) fails with Permission denied and also breaks the rule that a lib being processed writes only inside its own `third_party/<pin>/`.

- ro, rw and upgrade all materialize `src/` the same single way:
  `git -c safe.directory=<host> clone --no-hardlinks --no-checkout <host> <src>` then `git -C <src> checkout --detach <sha>`.
  This copies objects (no alternates), so it survives the host being gc'd/pruned, and only reads the host. Disk use is acceptable (David confirmed).
  Replaces both `worktree add` (rw ~L1079-1105, upgrade ~L1353) and the `--shared` clone from e21ad52d.
- Any existing linked-worktree or `--shared` src is replaced (one clear message saying so).
- `-c safe.directory=<resolved absolute host path>` on every git call against a host repo, in fetch-deps and libpin-sandbox. Trust only that path; no global safe.directory edits, no `*`.
- Show git's real stderr on any host failure (e.g. "detected dubious ownership"), never a rewritten "not a git repo".
- libpin-sandbox: remove host `.git` write access entirely (drop LIBPIN_HOST_GIT write grants). Host is read-only inside the sandbox; writes only inside `third_party/<pin>/`.
- upgrade: branches are created in `src/` only, never in the host. Clean them up on success.
- rw: edits live in the src clone. rw prints how to push them back to the host (that push is David's action, not the tool's).
- If the agent user lacks READ access to a host repo, fail naming the path, the missing permission and the command David would run.

## host_repo
- Optional libpin.toml key; defaults to the pin name.
- Value: repo name under git_home, or an absolute path OUTSIDE git_home. An absolute path inside git_home is an error (use the name).
- One shared resolve-host helper used by fetch-deps (local_repo_for, refresh, ro, rw, upgrade, remove_linked_worktree_src) and libpin-sandbox.
- If a host repo exists for a pin, never use the network: missing repo or missing commit is an error.
- Leak check: `fetch-deps check` (and a pre-commit hook if the project uses one) warns if a committed libpin.toml contains the expanded git_home path (the clean filter didn't run).

## Code fixes
1. errexit: `cmd_x || FAILURES=...` disables set -e inside cmd_*. Restructure (e.g. run each in a subshell with `set -e`) so any failing step aborts. Before recording a sha, verify `git -C "$src" rev-parse --show-toplevel` == "$src" so the consumer repo's HEAD can never be pinned.
2. get-artifacts: remove the basename `find` fallback when a glob matches nothing (zero matches = failure). Exactly one match unless an explicit pick mode is set; reject unknown pick values (no `newest|*`, no smart->newest).
3. Remove swallowed errors: git_https `|| true`; requires_writable_src (use pin_get_opt); status.local `|| echo ro`; `ve_branch || echo unknown`; git calls with 2>/dev/null; libpin-sandbox `resolve_host_git ... 2>/dev/null || true`; artifact rows without `from` (fail).
4. Remove fallback chains: invalid host -> network; host missing commit -> network; leftover smudge token -> network; fetch-by-sha -> fetch-all; https -> ssh -> seed-src; worktree-add -> clone; curl -> wget; tomllib -> tomli (require Python >= 3.11). One transport per pin. Missing sandbox tool is an error unless --no-bwrap/--no-landlock is given explicitly.
5. Sandbox: the LIBPIN_SANDBOX environment variable alone must not skip sandboxing; use a check a build step can't fake.
6. Artifact sha256 required. A placeholder is allowed only under --record, which fills it in (including new rows).
7. upgrade reproducibility check: build twice from a clean state (fresh clone or git clean -xfd plus build dirs), not an incremental rebuild.
8. Patches: reject paths with `..` or a leading `/`; run patch cleanup inside the sandbox; apply patches for file pins (or fail if a file pin has patches); apply *.patch and *.diff as one sorted list.
9. record_artifact_shas: drop the artifacts/from_src aliases or verify row count == parsed count; fail on mismatch.
10. write_pin_sha: edit only the top-level git_sha, escape values, write temp file then rename.
11. Exact path matches (no `grep -q "$src"` substring/regex matches).
12. get-artifacts resolve_dest: destinations must resolve inside REPO_ROOT (realpath).
13. Remove hard-coded project names (rclone|paddle|example in fetch-deps, example in get-artifacts). Use a pin key such as `default = false`, same in both scripts.
14. upgrade: don't overwrite existing EXIT traps; write status only after patching succeeds.

## Features
A. `depends = ["<pin>"]`: for a pin whose repo carries its own pins (extractmail carries remotetable), `fetch-deps check` reads the nested libpin.toml at the pinned commit and fails if its sha for the shared dependency differs from this tree's pin, naming both shas.
B. `fetch-deps outdated`: compare each pin with its upstream (host repo, or the track_branch remote). Store the tip seen at the last check in status.local; report separately (a) upstream moved since the last check and (b) still behind, no new movement. Read-only apart from status.local.
C. refresh uses track_branch instead of hard-coded master. Tag pins store the tag and fail if it now resolves to a different commit (moved tag).
D. Submodules/LFS: when materializing a source, fail loudly if it has a .gitmodules file or contains Git LFS pointer files.
E. Companion version: fetch-deps, get-artifacts and libpin-sandbox (plus bwrap/landlock helpers) carry one shared version stamp; fetch-deps refuses to run if its companions' version differs, naming the mismatch. They are always published as one set.

## Out of scope
Toolchain provenance for reproducible=false pins; a shared large-file cache; build variants; offline mode beyond git_home; upgrade dry-run/changelog.

## Tests
Extend the kit tests/examples to cover: errexit abort; zero-match failure; ambiguous partial sha; no network when a host repo exists; host repo owned by another user is read via a clone with no writes to its .git; sandbox denies writes to host .git; required sha256; patch path rejection; host_repo resolution and git_home absolute-path rejection; git_home leak warning; depends mismatch; outdated reporting; moved-tag check; companion version mismatch. Run them, plus orchestration-example's tools/audit-swallow against kit/.

## Report back
Commits made; each item done or not with reason; test results; behavior changes that will affect existing pins in VehicleExpenses-automated, liveimap, torque-ford-gas-tracking, extractmail and remotetable when published; and any permission changes David must make (with exact commands).

---

## Rev 2 (2026-10-24): answers to the implementer's review. Where this conflicts with anything above, this section wins.

### Work in phases, each with tests, each committed
1. Step 0 merge: orchestration-example's fetch-deps/get-artifacts (--record, upgrade restore, swallow cleanups) as the base; add host_repo from 42450702; keep git_repo_error / real git stderr from e21ad52d; do NOT keep e21ad52d's alternates (--shared).
2. Host read-only: resolve-host helper, clone --no-hardlinks, safe.directory, drop LIBPIN_HOST_GIT writes and resolve_host_git from libpin-sandbox, replace linked/--shared src.
3. Fail-loud: errexit, swallow removal, no network fallbacks, one transport, Python >= 3.11, curl only, sandbox tools required, show-toplevel guard, exact path matches.
4. Artifacts: required sha256, --record fills placeholders and inserts new rows, zero-match fails, pick, drop aliases, resolve_dest under REPO_ROOT, default = false.
5. Features A-E (shared `fetch-deps check` command for leak warning, host_repo validation, depends, moved tag).
6. Docs: PIN_FORMAT, SANDBOX, GUIDE, QUICKSTART, README.

### Materialize decision tree
```
host = host_repo (name under GIT_HOME, or absolute path) else GIT_HOME/<name>
absolute host path under GIT_HOME          -> error (use the name)
GIT_HOME/<name> exists but is not a git repo -> error
leftover smudge token (@@GIT_HOME@@)       -> error
if host_repo set OR host is a git repo:
    require read access (else print the chmod/setfacl David would run)
    resolve sha (partial -> unique full sha, else error)
    reuse src if it is a standalone clone (toplevel == src, no alternates, not linked) and has the commit; else
    clone --no-hardlinks --no-checkout host src; checkout --detach sha
    never network
elif declared network transport (git_https) or declared seed-src:
    that transport only
else: error
```

### Answers
1. Network: exactly the tree above. host_repo set or GIT_HOME/<name> is a git repo -> host only. Neither -> git_https. Non-git dir at GIT_HOME/<name> -> fail. Smudge token -> fail.
2. Transport: git_https is the network transport. git_ssh is recorded metadata, not used by the tool. seed-src is used only when declared explicitly (e.g. `source = "seed-src"`); an empty git_https does not imply it. Update kit/example accordingly.
3. Sandbox tools: missing bwrap/landlock is an error everywhere (Linux, non-Linux, CI) with the message "pass --no-bwrap --no-landlock to run unsandboxed". No platform auto-detection. Docs updated to match.
4. Multiple names: a failed pin aborts that pin only; later names still run; exit non-zero at the end with every failure listed.
5. Pick: omitted pick -> exactly one match required. pick = "newest" stays valid when written explicitly. Unknown values are errors. kit/example sets pick = "newest".
6. Placeholder: only 64 zeros. --record replaces it. A missing sha256 key is an error except under --record, which inserts the line into that [[artifact]] table (temp file + rename). Empty or "TBD" are errors.
7. Tags: track_branch is looked up in the host as refs/tags/X and refs/heads/X. Both exist -> error. Branch -> refresh moves along that branch. Tag -> refresh only verifies the tag still resolves to the pinned sha (fail "tag moved" otherwise); changing it requires `upgrade --ref`. Delete the master and host/master/.git special cases and offer_mainish_retarget.
8. rw: at clone time set origin = git_https (when present) and add remote `host` = resolved host path. rw/upgrade do `checkout -B <branch>` in src. Print, for David: `git -C <src> push host HEAD:refs/heads/<branch>`.
9. Old linked worktrees: rm -rf src is fine; print `git -C <host> worktree prune` for David. Leftover host metadata is acceptable until he runs it.
10. Reuse a standalone full clone already at, or containing, the sha (checkout --detach); fetch a missing commit from host into it. Only re-clone linked/--shared/wrong-toplevel src.
11. LIBPIN_SANDBOX: yes, detect confinement with a write probe outside the pin's writable area; probe failing = already confined, skip nesting; probe succeeding = apply bwrap. The env var alone never skips the sandbox. Remove the probe file on success and fail loudly if it can't be removed.
12. depends: `git show <pin-sha>:third_party/<dep>/libpin.toml` in the host. Compare git_sha only (resolved to full shas).
13. Companion version: one `kit/VERSION` file. fetch-deps, get-artifacts and libpin-sandbox each refuse to run on mismatch, including when invoked alone.
14. Tests go in kit/tests/, seeded from orchestration-example tools/test-fetch-deps-record with throwaway --git-home fixtures. The other-owner case: a documented manual probe plus safe.directory unit coverage if a chown fixture is impossible without root. Docs are in scope (phase 6).
15. Remove all project coupling: VE_ROOT, ve_branch, chgrp ai-code/chmod 664 (leave group bits to umask/ACLs), hard-coded git_home (must come from configuration/flag; fail if unset), and the rclone/paddle/example skip list (replaced by default = false). --worktree-search: report what it does; remove it if it is a project-specific special case.

### Also agreed
- show-toplevel == src check in every path that records a sha (ro, refresh, upgrade, write_pin_sha).
- apply_patches honors `patches = [...]` order when present, else one sorted list of *.patch and *.diff; path rejection on both.
- write_pin_sha: temp file + rename, top-level only, no chgrp.
- Upgrade: write status.local only after a successful patch; on failure keep src and its branch for debugging; on success delete the branch in src and detach at the new pin.
- safe.directory only on git calls against the host, never on the agent-owned src, never `*`.
- Keep the image-pin plan separate; don't touch it.
- Include the consumer-impact table from the review in the report, updated for these answers (rclone/paddle need default = false; paddle-opt needs a real sha256 via --record; extractmail gets depends = ["remotetable"]; opencv becomes a tag check; David runs worktree prune once per host).
