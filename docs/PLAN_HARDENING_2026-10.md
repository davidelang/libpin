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
