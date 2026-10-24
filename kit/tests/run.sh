#!/usr/bin/env bash
# Tests for hardened fetch-deps / get-artifacts / sandbox (throwaway repos in /tmp).
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d /tmp/libpin-test.XXXXXX)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
G() { git -c user.name=t -c user.email=t@t "$@"; }

GH="$T/gh"; mkdir -p "$GH/toy"
G -C "$GH/toy" init -q -b master
echo v1 >"$GH/toy/content"; G -C "$GH/toy" add -A; G -C "$GH/toy" commit -qm v1; V1=$(git -C "$GH/toy" rev-parse HEAD)
echo v2 >"$GH/toy/content"; G -C "$GH/toy" commit -qam v2; V2=$(git -C "$GH/toy" rev-parse HEAD)
G -C "$GH/toy" tag -a v1tag -m v1 "$V1"
H1=$(printf 'built v1\n' | sha256sum | cut -d' ' -f1)
H2=$(printf 'built v2\n' | sha256sum | cut -d' ' -f1)
ZERO=0000000000000000000000000000000000000000000000000000000000000000

install_kit() {
  local dest="$1"
  mkdir -p "$dest"
  cp "$KIT/fetch-deps" "$KIT/get-artifacts" "$KIT/libpin-sandbox" "$KIT/libpin-bwrap" "$KIT/libpin-landlock" "$KIT/VERSION" "$dest/"
  chmod +x "$dest/fetch-deps" "$dest/get-artifacts" "$dest/libpin-sandbox" "$dest/libpin-bwrap" "$dest/libpin-landlock"
}

mkrepo() {  # mkrepo REPRODUCIBLE BUILDCMD [extra toml]
  R="$T/repo"
  if [[ -d "$R" ]]; then chmod -R u+w "$R"; rm -rf "$R"; fi
  mkdir -p "$R/third_party/toy"
  install_kit "$R/third_party"
  cat >"$R/third_party/toy/libpin.toml" <<P
name = "toy"
git_https = "https://invalid.example/toy.git"
git_sha = "$V1"
git_describe = "v1"
track_branch = "master"
reproducible = $1
build = ["./build"]
${3:-}
[[artifact]]
from = "src/out.bin"
path = "artifact/out.bin"
sha256 = "$H1"
P
  # rm first: after make_readonly_tree, src/out.bin is a-w; the dir stays writable.
  printf '#!/bin/bash\nset -e\nrm -f src/out.bin\n%s\n' "$2" >"$R/third_party/toy/build"
  chmod 755 "$R/third_party/toy/build"
  G -C "$R" init -q -b master
  G -C "$R" add -A
  G -C "$R" commit -qm init
}
fd() { (cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock --git-home "$GH" "$@") >"$T/out" 2>&1; }
fd_sbx() { (cd "$R" && ./third_party/fetch-deps --git-home "$GH" "$@") >"$T/out" 2>&1; }
pin() { cat "$R/third_party/toy/libpin.toml"; }
tailout() { tail -20 "$T/out"; }

# --- record / upgrade (seeded from orch test-fetch-deps-record) ---
mkrepo true 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
fd ro toy; rc=$?; [[ $rc -eq 0 ]] && ok "materialize pin v1" || bad "ro rc=$rc $(tailout)"
fd build toy; rc=$?; [[ $rc -eq 0 ]] && ok "build at the pin verifies sha256" || bad "build rc=$rc $(tailout)"
fd upgrade toy --ref "$V2"; rc=$?
[[ $rc -eq 0 ]] && ok "upgrade to a new commit succeeds" || bad "upgrade rc=$rc $(tailout)"
pin | grep -q "sha256 = \"$H2\"" && pin | grep -q "git_sha = \"$V2\"" && ok "pin now has the new git_sha and artifact sha256" || bad "pin after upgrade: $(pin)"
grep -q "record sha256 artifact/out.bin: $H1 -> $H2" "$T/out" && ok "old -> new printed" || bad "no old->new line: $(cat "$T/out")"
grep -q 'second build must give the recorded bytes' "$T/out" && ok "reproducible pin built twice" || bad "no second build"
grep -q '^ARTIFACT-SHA256' "$T/out" && bad "raw record lines leaked to the user" || ok "record lines consumed by fetch-deps"
grep -q "git_describe" "$R/third_party/toy/libpin.toml" && grep -q "$V2" "$R/third_party/toy/libpin.toml" && ok "git_describe updated with git_sha" || bad "git_describe: $(pin)"
fd build toy; rc=$?; [[ $rc -eq 0 ]] && ok "plain build after upgrade verifies the recorded sha256" || bad "post-upgrade build rc=$rc"

sed -i "s/sha256 = \"$H2\"/sha256 = \"$H1\"/" "$R/third_party/toy/libpin.toml"
fd build toy; rc=$?
[[ $rc -ne 0 ]] && grep -q "FAIL sha256 src/out.bin: got $H2 want $H1" "$T/out" && ok "verify mode fails on a mismatch" || bad "verify mismatch rc=$rc $(tailout)"
fd build --record toy; rc=$?
[[ $rc -eq 0 ]] && pin | grep -q "sha256 = \"$H2\"" && ok "build --record writes the new sha256" || bad "build --record rc=$rc $(pin)"

mkrepo true 'printf "built %s %s\n" "$(cat src/content)" "$(date +%N)" >src/out.bin'
fd ro toy; before=$(pin)
fd upgrade toy --ref "$V2"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'not reproducible' "$T/out" && ok "non-reproducible upgrade fails" || bad "non-repro upgrade rc=$rc $(tailout)"
[[ "$(pin)" == "$before" ]] && ok "pin unchanged after the failed upgrade" || bad "pin changed: $(pin)"
ls "$R/third_party/toy/" | grep -q before-upgrade && bad "backup left behind" || ok "no backup file left behind"
[[ -d "$R/third_party/toy/src" ]] && git -C "$R/third_party/toy/src" rev-parse --abbrev-ref HEAD >/dev/null && ok "failed upgrade kept src" || ok "failed upgrade kept src (detached or branch)"

mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
fd ro toy; fd upgrade toy --ref "$V2"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'second build' "$T/out" && pin | grep -q "sha256 = \"$H2\"" && ok "reproducible = false: single build, recorded" || bad "non-repro pin rc=$rc $(tailout)"

# placeholder 64 zeros + insert missing sha256
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s/sha256 = \"$H1\"/sha256 = \"$ZERO\"/" "$R/third_party/toy/libpin.toml"
fd ro toy; fd build --record toy; rc=$?
[[ $rc -eq 0 ]] && pin | grep -q "sha256 = \"$H1\"" && ok "--record fills 64-zero placeholder" || bad "placeholder rc=$rc $(pin) $(tailout)"

mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
python3 - "$R/third_party/toy/libpin.toml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
t = t.replace("sha256 = \"%s\"\n" % open("/dev/null","w") and "", "")
PY
# strip sha256 line
sed -i '/^sha256 = /d' "$R/third_party/toy/libpin.toml"
fd ro toy; fd build toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'sha256 is required' "$T/out" && ok "missing sha256 fails in verify" || bad "missing sha256 rc=$rc $(tailout)"
fd build --record toy; rc=$?
[[ $rc -eq 0 ]] && grep -q "sha256 = \"$H1\"" "$R/third_party/toy/libpin.toml" && ok "--record inserts a new sha256 row" || bad "insert rc=$rc $(pin) $(tailout)"

# zero glob matches
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i 's#from = "src/out.bin"#from = "src/nope-*.bin"\npick = "newest"#' "$R/third_party/toy/libpin.toml"
fd ro toy; fd build toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no file for from=src/nope-\*.bin' "$T/out" && ok "zero glob matches fail" || bad "zero glob rc=$rc $(tailout)"

# default = false omitted from default NAME set
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
mkdir -p "$R/third_party/skipme"
cat >"$R/third_party/skipme/libpin.toml" <<P
name = "skipme"
default = false
source_kind = "files"
build = []
P
fd ro; rc=$?
[[ $rc -eq 0 ]] && [[ ! -d "$R/third_party/skipme/src" ]] && [[ -d "$R/third_party/toy/src" ]] && ok "default = false omitted from default set" || bad "default=false rc=$rc $(tailout)"

# errexit: later pins still run
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
mkdir -p "$R/third_party/bad"
cat >"$R/third_party/bad/libpin.toml" <<P
name = "bad"
git_https = "https://invalid.example/bad.git"
git_sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
P
fd ro bad toy; rc=$?
[[ $rc -ne 0 ]] && grep -q "FAIL bad" "$T/out" && [[ -d "$R/third_party/toy/src" ]] && grep -q "failures=1): bad" "$T/out" && ok "errexit abort with later pins still running" || bad "errexit rc=$rc $(tailout)"

# no network when a host exists
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
mkdir -p "$T/bin"
cat >"$T/bin/git" <<'EOF'
#!/bin/bash
echo "git-wrapper: $*" >>"${GIT_WRAP_LOG:?}"
exec /usr/bin/git "$@"
EOF
chmod +x "$T/bin/git"
GIT_WRAP_LOG="$T/git.log"; export GIT_WRAP_LOG
: >"$T/git.log"
PATH="$T/bin:$PATH" fd ro toy; rc=$?
[[ $rc -eq 0 ]] && ! grep -Eq 'clone .*invalid\.example|fetch .*invalid\.example' "$T/git.log" && grep -q 'safe.directory=' "$T/git.log" && ok "no network when a host exists; safe.directory on host git" || bad "network/host rc=$rc log=$(cat "$T/git.log") $(tailout)"
unset GIT_WRAP_LOG
PATH="${PATH#$T/bin:}"

# non-git GIT_HOME/<name> is a skipped shortcut; no remote → fail
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
mkdir -p "$T/gh-notgit/toy"
echo notgit >"$T/gh-notgit/toy/file"
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock --git-home "$T/gh-notgit" ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'not a git repo' "$T/out" && grep -q 'no usable host shortcut' "$T/out" && ok "non-git GIT_HOME/<name> without remote fails" || bad "notgit rc=$rc $(tailout)"

# non-git shortcut + git_https uses the remote
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock --git-home "$T/gh-notgit" ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'skipping it' "$T/out" && [[ -f "$R/third_party/toy/src/content" ]] && ok "non-git shortcut falls through to git_https" || bad "notgit+https rc=$rc $(tailout)"

# smudge token
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock --git-home '@@GIT_HOME@@' ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'leftover smudge token' "$T/out" && ok "smudge token is an error" || bad "smudge rc=$rc $(tailout)"

# GIT_HOME unset + host_repo name uses git_https (host is never mandatory)
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"toy\"|" "$R/third_party/toy/libpin.toml"
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && [[ -f "$R/third_party/toy/src/content" ]] && ok "GIT_HOME unset + host_repo name uses git_https" || bad "host optional rc=$rc $(tailout)"

# GIT_HOME unset + host_repo name + no remote fails
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"toy\"|" "$R/third_party/toy/libpin.toml"
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no usable host shortcut' "$T/out" && ok "host_repo name without GIT_HOME or remote fails" || bad "host+noremote rc=$rc $(tailout)"

# unreadable host: report chmod/setfacl, use git_https
BLOCK="$T/blocked/toy"
mkdir -p "$T/blocked"
cp -a "$GH/toy" "$BLOCK"
chmod a-rx "$BLOCK"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$BLOCK\"|" "$R/third_party/toy/libpin.toml"
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'chmod a+rX' "$T/out" && grep -q 'setfacl' "$T/out" && grep -q 'chown -R dlang:dlang' "$T/out" && [[ -f "$R/third_party/toy/src/content" ]] && ok "unreadable host reports David chmod and uses git_https" || bad "blocked host rc=$rc $(tailout)"
chmod u+rwx "$BLOCK"
chmod -R u+rwx "$T/blocked"

# unreadable host, no remote: fail with the same David commands
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$BLOCK\"|" "$R/third_party/toy/libpin.toml"
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
chmod a-rx "$BLOCK"
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'chmod a+rX' "$T/out" && grep -q 'chown -R dlang:dlang' "$T/out" && grep -q 'no usable host shortcut' "$T/out" && ok "unreadable host without remote fails with chmod help" || bad "blocked noremote rc=$rc $(tailout)"
chmod u+rwx "$BLOCK"
chmod -R u+rwx "$T/blocked"

# git_ssh is a real transport when git_https is absent
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
sed -i "s|^name = \"toy\"|name = \"toy\"\ngit_ssh = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && [[ -f "$R/third_party/toy/src/content" ]] && grep -q "remote $GH/toy" "$T/out" && ok "git_ssh used when no host and no git_https" || bad "git_ssh rc=$rc $(tailout)"

# git_https is preferred over git_ssh (agents)
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
sed -i "s|^name = \"toy\"|name = \"toy\"\ngit_ssh = \"git@should-not-be-used.example:toy.git\"|" "$R/third_party/toy/libpin.toml"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q "remote $GH/toy" "$T/out" && ! grep -q 'should-not-be-used' "$T/out" && ok "git_https preferred over git_ssh" || bad "https-pref rc=$rc $(tailout)"

# readable host without the pin sha falls through to git_https
EMPTYH="$T/emptyhost"
rm -rf "$EMPTYH"
mkdir -p "$EMPTYH"
G -C "$EMPTYH" init -q -b master
echo other >"$EMPTYH/content"; G -C "$EMPTYH" add -A; G -C "$EMPTYH" commit -qm other
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$EMPTYH\"|" "$R/third_party/toy/libpin.toml"
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'does not have' "$T/out" && grep -q 'declared fallback to remote' "$T/out" && grep -q "remote $GH/toy" "$T/out" && grep -q v1 "$R/third_party/toy/src/content" && ok "host missing sha falls through to git_https" || bad "host-miss-sha rc=$rc $(tailout)"

# ssh URL permission/key failure prints a command David can run
mkdir -p "$T/sshbin"
cat >"$T/sshbin/ssh" <<'EOF'
#!/bin/bash
echo "git@invalid.example: Permission denied (publickey)." >&2
exit 255
EOF
chmod +x "$T/sshbin/ssh"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
sed -i 's|^name = "toy"|name = "toy"\ngit_ssh = "git@invalid.example:toy.git"|' "$R/third_party/toy/libpin.toml"
(cd "$R" && env PATH="$T/sshbin:$PATH" GIT_SSH="$T/sshbin/ssh" GIT_SSH_COMMAND="$T/sshbin/ssh" ./third_party/fetch-deps --no-bwrap --no-landlock ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'David: ssh -T git@invalid.example' "$T/out" && grep -q 'David: git clone git@invalid.example:toy.git' "$T/out" && grep -q 'chmod 700 /home/dlang/.ssh' "$T/out" && ok "ssh failure prints David ssh/clone commands" || bad "ssh help rc=$rc $(tailout)"

# refresh without GIT_HOME uses git_https
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock refresh toy) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q "pin → $V2" "$T/out" && ok "refresh without host uses git_https" || bad "refresh remote rc=$rc $(tailout)"

# host_repo name under GIT_HOME works; absolute inside GIT_HOME rejected
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"toy\"|" "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && ok "host_repo name resolves under GIT_HOME" || bad "host_repo name rc=$rc $(tailout)"
sed -i "s|host_repo = \"toy\"|host_repo = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'use the name' "$T/out" && ok "absolute host_repo under GIT_HOME rejected" || bad "abs inside rc=$rc $(tailout)"

# absolute host_repo outside GIT_HOME
OTHER="$T/other/lib"
mkdir -p "$OTHER"
G -C "$OTHER" init -q -b master
echo v1 >"$OTHER/content"; G -C "$OTHER" add -A; G -C "$OTHER" commit -qm v1
OV=$(git -C "$OTHER" rev-parse HEAD)
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s/git_sha = \"$V1\"/git_sha = \"$OV\"/" "$R/third_party/toy/libpin.toml"
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$OTHER\"|" "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && ok "absolute host_repo outside GIT_HOME" || bad "abs outside rc=$rc $(tailout)"

# GIT_HOME unset + files / seed-src / git_https
R="$T/repo"; chmod -R u+w "$R"; rm -rf "$R"
mkdir -p "$R/third_party/fp/seed" "$R/third_party"
install_kit "$R/third_party"
printf 'hello-file\n' >"$R/third_party/fp/seed/hello.txt"
FSHA=$(sha256sum "$R/third_party/fp/seed/hello.txt" | awk '{print $1}')
cat >"$R/third_party/fp/libpin.toml" <<P
name = "fp"
source_kind = "files"
build = []
[[source]]
seed = "seed/hello.txt"
path = "hello.txt"
sha256 = "$FSHA"
P
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock ro fp) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && [[ -f "$R/third_party/fp/src/hello.txt" ]] && ok "GIT_HOME unset + files pin runs" || bad "files unset rc=$rc $(tailout)"

mkdir -p "$R/third_party/ex"
cat >"$R/third_party/ex/libpin.toml" <<'P'
name = "ex"
source_kind = "seed-src"
git_sha = "0000000000000000000000000000000000000001"
build = []
P
cat >"$R/third_party/ex/seed-src" <<'S'
#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/src"
rm -rf "$SRC"; mkdir -p "$SRC"; cd "$SRC"
git init -q
git config user.email e@e; git config user.name e
echo seed >README.txt
git add README.txt
git commit -q -m seed
S
chmod +x "$R/third_party/ex/seed-src"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock ro ex) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && [[ -d "$R/third_party/ex/src/.git" ]] && ok "GIT_HOME unset + seed-src runs" || bad "seed-src unset rc=$rc $(tailout)"

mkdir -p "$R/third_party/httpspin"
cat >"$R/third_party/httpspin/libpin.toml" <<P
name = "httpspin"
git_https = "$GH/toy"
git_sha = "$V1"
build = []
P
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock ro httpspin) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && [[ -f "$R/third_party/httpspin/src/content" ]] && ok "GIT_HOME unset + git_https runs" || bad "https unset rc=$rc $(tailout)"

# linked-worktree replacement
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
fd ro toy
chmod -R u+w "$R/third_party/toy/src"
rm -rf "$R/third_party/toy/src"
git -C "$GH/toy" worktree add -q --detach "$R/third_party/toy/src" "$V1" >/dev/null
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'replacing linked-worktree' "$T/out" && grep -q 'worktree prune' "$T/out" && [[ -d "$R/third_party/toy/src/.git" ]] && ok "linked-worktree replacement message" || bad "worktree rc=$rc $(tailout)"

# src reuse
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'reuse standalone src' "$T/out" && ok "src reuse" || bad "reuse rc=$rc $(tailout)"

# show-toplevel guard
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
fd ro toy
chmod -R u+w "$R/third_party/toy/src"
rm -rf "$R/third_party/toy/src"
ln -s "$R" "$R/third_party/toy/src"
fd refresh toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'show-toplevel' "$T/out" && ok "show-toplevel guard" || bad "toplevel rc=$rc $(tailout)"

# default branch names and --branch
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
fd rw toy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'branch=work' "$T/out" && ok "rw default branch work" || bad "rw branch rc=$rc $(tailout)"
fd rw toy --branch custom; rc=$?
[[ $rc -eq 0 ]] && grep -q 'branch=custom' "$T/out" && ok "--branch overrides rw" || bad "rw --branch rc=$rc $(tailout)"
fd upgrade toy --ref "$V2"; rc=$?
[[ $rc -eq 0 ]] && grep -q "upgrade/$V2" "$T/out" && ok "upgrade default branch upgrade/<ref>" || bad "upgrade branch rc=$rc $(tailout)"

# file pin with patches rejected
R="$T/repo"; chmod -R u+w "$R"; rm -rf "$R"
mkdir -p "$R/third_party/fp/seed" "$R/third_party/fp/patches"
install_kit "$R/third_party"
printf 'hello-file\n' >"$R/third_party/fp/seed/hello.txt"
FSHA=$(sha256sum "$R/third_party/fp/seed/hello.txt" | awk '{print $1}')
cat >"$R/third_party/fp/libpin.toml" <<P
name = "fp"
source_kind = "files"
build = []
[[source]]
seed = "seed/hello.txt"
path = "hello.txt"
sha256 = "$FSHA"
P
echo dummy >"$R/third_party/fp/patches/x.patch"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock --git-home "$GH" ro fp) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'cannot have a patches/' "$T/out" && ok "file pin with patches/ rejected" || bad "file patches rc=$rc $(tailout)"

# patch path rejection and order
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
mkdir -p "$R/third_party/toy/patches"
python3 - "$R/third_party/toy/libpin.toml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
t = t.replace('build = ["./build"]', 'build = ["./build"]\npatches = ["../escape.patch"]')
p.write_text(t)
PY
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'patch path rejected' "$T/out" && ok "patch path with .. rejected" || bad "patch .. rc=$rc $(tailout)"

# two patches: b then a in the declared order (sorted would be a then b)
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
PT="$T/patchsrc"
rm -rf "$PT"; mkdir -p "$PT"
G -C "$PT" init -q -b master
G -C "$PT" commit -qm init --allow-empty
echo B >"$PT/order.txt"
G -C "$PT" add order.txt
G -C "$PT" commit -qm B
G -C "$PT" format-patch -1 --stdout >"$T/b.patch"
echo BA >"$PT/order.txt"
G -C "$PT" commit -qam BA
G -C "$PT" format-patch -1 --stdout >"$T/a.patch"
mkdir -p "$R/third_party/toy/patches"
cp "$T/b.patch" "$R/third_party/toy/patches/b.patch"
cp "$T/a.patch" "$R/third_party/toy/patches/a.patch"
python3 - "$R/third_party/toy/libpin.toml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
t = t.replace('build = ["./build"]', 'build = ["./build"]\npatches = ["patches/b.patch", "patches/a.patch"]')
p.write_text(t)
PY
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && grep -q BA "$R/third_party/toy/src/order.txt" && ok "patch order honors patches = [...]" || bad "patch order rc=$rc $(tailout) $(cat "$R/third_party/toy/src/order.txt" 2>/dev/null)"

# moved tag / tag+branch / outdated
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i 's/track_branch = "master"/track_branch = "v1tag"/' "$R/third_party/toy/libpin.toml"
fd check toy; rc=$?
[[ $rc -eq 0 ]] && ok "tag track_branch still at pin" || bad "tag check rc=$rc $(tailout)"
git -C "$GH/toy" tag -d v1tag >/dev/null
git -C "$GH/toy" tag -a v1tag -m moved "$V2"
fd check toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'tag moved' "$T/out" && ok "moved tag fails check" || bad "moved tag rc=$rc $(tailout)"
fd refresh toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'tag moved' "$T/out" && ok "moved tag fails refresh" || bad "moved tag refresh rc=$rc $(tailout)"
git -C "$GH/toy" tag -d v1tag >/dev/null
git -C "$GH/toy" tag -a v1tag -m v1 "$V1"
git -C "$GH/toy" branch v1tag "$V2" 2>/dev/null || git -C "$GH/toy" branch -f v1tag "$V2"
fd check toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'both a tag and a branch' "$T/out" && ok "tag+branch ambiguity" || bad "tag+branch rc=$rc $(tailout)"
git -C "$GH/toy" branch -D v1tag >/dev/null

mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
fd ro toy
fd outdated toy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'behind upstream' "$T/out" && ok "outdated: behind, no previous check" || bad "outdated1 rc=$rc $(tailout)"
fd outdated toy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'still behind with no new movement' "$T/out" && ok "outdated: still behind, no new movement" || bad "outdated2 rc=$rc $(tailout)"
echo v3 >"$GH/toy/content"; G -C "$GH/toy" commit -qam v3; V3=$(git -C "$GH/toy" rev-parse HEAD)
fd outdated toy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'upstream moved since last check' "$T/out" && ok "outdated: upstream moved since last check" || bad "outdated3 rc=$rc $(tailout)"
git -C "$GH/toy" reset --hard "$V2" >/dev/null

# submodule / LFS
mkdir -p "$GH/submod"
G -C "$GH/submod" init -q -b master
echo x >"$GH/submod/file"; echo '[submodule "x"]' >"$GH/submod/.gitmodules"
G -C "$GH/submod" add -A; G -C "$GH/submod" commit -qm sub
SM=$(git -C "$GH/submod" rev-parse HEAD)
mkrepo false 'true'
sed -i "s/git_sha = \"$V1\"/git_sha = \"$SM\"/" "$R/third_party/toy/libpin.toml"
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$GH/submod\"|" "$R/third_party/toy/libpin.toml"
# host_repo absolute under? GH/submod is not under GH if GH is $T/gh and submod is $T/gh/submod — that IS under GIT_HOME.
# Use --git-home $T so host_repo absolute $GH/submod is under $T? GIT_HOME=$GH=$T/gh, $GH/submod is under GIT_HOME.
# So use host_repo name: put repo at $GH/submod and host_repo = "submod" but pin name is toy.
# host_repo = "submod" with GIT_HOME=$GH.
rm -f "$R/third_party/toy/libpin.toml"
cat >"$R/third_party/toy/libpin.toml" <<P
name = "toy"
host_repo = "submod"
git_sha = "$SM"
build = []
P
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'gitmodules' "$T/out" && ok "submodule refusal" || bad "submodule rc=$rc $(tailout)"

mkdir -p "$GH/lfs"
G -C "$GH/lfs" init -q -b master
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize 1\n' "$ZERO" >"$GH/lfs/big.bin"
G -C "$GH/lfs" add -A; G -C "$GH/lfs" commit -qm lfs
LF=$(git -C "$GH/lfs" rev-parse HEAD)
cat >"$R/third_party/toy/libpin.toml" <<P
name = "toy"
host_repo = "lfs"
git_sha = "$LF"
build = []
P
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'Git LFS pointer' "$T/out" && ok "LFS refusal" || bad "lfs rc=$rc $(tailout)"

# depends: via src, via host, neither, mismatch
mkdir -p "$GH/parent/third_party/dep"
G -C "$GH/parent" init -q -b master
cat >"$GH/parent/third_party/dep/libpin.toml" <<P
name = "dep"
git_sha = "$V1"
P
echo p >"$GH/parent/README"; G -C "$GH/parent" add -A; G -C "$GH/parent" commit -qm p
PV=$(git -C "$GH/parent" rev-parse HEAD)
# mismatch: consumer dep pin is V2
R="$T/repo"; chmod -R u+w "$R"; rm -rf "$R"
mkdir -p "$R/third_party/parent" "$R/third_party/dep"
install_kit "$R/third_party"
cat >"$R/third_party/dep/libpin.toml" <<P
name = "dep"
git_https = "$GH/toy"
git_sha = "$V2"
build = []
P
cat >"$R/third_party/parent/libpin.toml" <<P
name = "parent"
host_repo = "parent"
git_sha = "$PV"
depends = ["dep"]
build = []
P
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock --git-home "$GH" check parent) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'depends dep mismatch' "$T/out" && ok "depends mismatch" || bad "depends mismatch rc=$rc $(tailout)"

# matching via host (no parent src)
cat >"$R/third_party/dep/libpin.toml" <<P
name = "dep"
git_https = "$GH/toy"
git_sha = "$V1"
build = []
P
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock --git-home "$GH" check parent) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'depends dep OK' "$T/out" && ok "depends via host" || bad "depends host rc=$rc $(tailout)"

# via src: materialize parent then check (src has the file)
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock --git-home "$GH" ro parent) >"$T/out" 2>&1
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock --git-home "$GH" check parent) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "depends via src" || bad "depends src rc=$rc $(tailout)"

# neither: no host, no src
cat >"$R/third_party/parent/libpin.toml" <<P
name = "parent"
git_https = "$GH/parent"
git_sha = "$PV"
depends = ["dep"]
build = []
P
rm -rf "$R/third_party/parent/src"
(cd "$R" && ./third_party/fetch-deps --no-bwrap --no-landlock check parent) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'need host or src' "$T/out" && ok "depends neither host nor src" || bad "depends neither rc=$rc $(tailout)"

# git_home leak warning
mkrepo false 'true'
python3 - "$R/third_party/toy/libpin.toml" "$GH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text() + f'\n# leak {sys.argv[2]}\n')
PY
fd check toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'expanded git_home' "$T/out" && grep -q 'pre-commit-git-home-leak' "$T/out" && ok "git_home leak warning" || bad "leak rc=$rc $(tailout)"

# companion version mismatch
mkrepo false 'true'
echo 1999.01.01 >"$R/third_party/VERSION"
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'VERSION mismatch' "$T/out" && ok "VERSION file mismatch (fetch-deps)" || bad "ver fd rc=$rc $(tailout)"
(cd "$R" && ./third_party/get-artifacts --no-bwrap --no-landlock toy) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'VERSION mismatch' "$T/out" && ok "VERSION file mismatch (get-artifacts)" || bad "ver ga rc=$rc $(tailout)"
(cd "$R" && ./third_party/libpin-sandbox --mode lib --lib toy -- true) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'VERSION mismatch' "$T/out" && ok "VERSION file mismatch (libpin-sandbox)" || bad "ver sbx rc=$rc $(tailout)"
(cd "$R" && ./third_party/libpin-bwrap --mode lib --lib toy -- true) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'VERSION mismatch' "$T/out" && ok "VERSION file mismatch (libpin-bwrap)" || bad "ver bw rc=$rc $(tailout)"
(cd "$R" && ./third_party/libpin-landlock --status) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'VERSION mismatch' "$T/out" && ok "VERSION file mismatch (libpin-landlock)" || bad "ver ll rc=$rc $(tailout)"
echo 2026.10.24 >"$R/third_party/VERSION"
sed -i 's/LIBPIN_VERSION=2026.10.24/LIBPIN_VERSION=1999.01.01/' "$R/third_party/fetch-deps"
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -q 'VERSION mismatch' "$T/out" && ok "embedded stamp mismatch (fetch-deps)" || bad "emb fd rc=$rc $(tailout)"
install_kit "$R/third_party"
sed -i 's/LIBPIN_VERSION=2026.10.24/LIBPIN_VERSION=1999.01.01/' "$R/third_party/libpin-bwrap"
(cd "$R" && ./third_party/libpin-sandbox --mode lib --lib toy -- true) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'stamp' "$T/out" && ok "helper stamp mismatch (libpin-sandbox checks bwrap)" || bad "helper stamp rc=$rc $(tailout)"
install_kit "$R/third_party"
sed -i 's/LIBPIN_VERSION = "2026.10.24"/LIBPIN_VERSION = "1999.01.01"/' "$R/third_party/libpin-landlock"
(cd "$R" && ./third_party/libpin-sandbox --mode lib --lib toy -- true) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'stamp' "$T/out" && ok "helper stamp mismatch (libpin-sandbox checks landlock)" || bad "ll stamp rc=$rc $(tailout)"

# missing sandbox tools (PATH with common tools but no bwrap)
mkrepo false 'true'
mkdir -p "$T/limited"
for t in bash sh python3 git curl env sha256sum realpath mktemp cat grep sed awk head tr date chmod mkdir rm cp mv ln ls find sort stat uname id cut basename dirname git-upload-pack git-receive-pack; do
  if p=$(command -v "$t"); then
    [[ -e "$T/limited/$t" ]] || ln -s "$p" "$T/limited/$t"
  fi
done
( export PATH="$T/limited"; cd "$R" && ./third_party/fetch-deps --git-home "$GH" ro toy ) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'pass --no-bwrap --no-landlock to run unsandboxed' "$T/out" && ok "missing bwrap is an error" || bad "missing bwrap rc=$rc $(tailout)"

# sandbox denies writes to host .git; LIBPIN_SANDBOX alone does not skip
mkrepo false 'true'
fd_sbx ro toy; rc=$?
[[ $rc -eq 0 ]] && ok "materialize under real sandbox" || bad "sbx ro rc=$rc $(tailout)"
(cd "$R" && env GIT_HOME="$GH" ./third_party/libpin-sandbox --mode lib --lib toy -- bash -c "echo ok >'$R/third_party/toy/inside' && echo pwn >'$GH/toy/.git/pwned'") >"$T/out" 2>&1; rc=$?
[[ -f "$R/third_party/toy/inside" ]] && [[ $rc -ne 0 ]] && [[ ! -e "$GH/toy/.git/pwned" ]] && ok "sandbox denies writes to host .git" || bad "host write rc=$rc inside=$(ls "$R/third_party/toy/inside" 2>/dev/null) $(tailout)"
(cd "$R" && env GIT_HOME="$GH" LIBPIN_SANDBOX=lib ./third_party/libpin-sandbox --mode lib --lib toy -- bash -c "echo ok >'$R/third_party/toy/inside2' && echo pwn >'$R/OUTSIDE'") >"$T/out" 2>&1; rc=$?
[[ -f "$R/third_party/toy/inside2" ]] && [[ $rc -ne 0 ]] && [[ ! -e "$R/OUTSIDE" ]] && ok "LIBPIN_SANDBOX alone does not skip the sandbox" || bad "LIBPIN_SANDBOX skip rc=$rc $(tailout)"

# ambiguous short sha
mkdir -p "$GH/amb"
G -C "$GH/amb" init -q -b master
echo 0 >"$GH/amb/f"; G -C "$GH/amb" add f; G -C "$GH/amb" commit -qm 0
python3 - "$GH/amb" <<'PY'
import subprocess, sys, collections
repo = sys.argv[1]
env = dict(**{k: v for k, v in __import__("os").environ.items()}, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
shas = []
for i in range(900):
    subprocess.check_call(["git", "-C", repo, "commit", "--allow-empty", "-qm", str(i)], env=env)
    shas.append(subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip())
pref = collections.defaultdict(list)
for s in shas:
    pref[s[:4]].append(s)
amb = next((k for k, v in pref.items() if len(v) > 1), None)
if not amb:
    sys.exit("no 4-char collision")
open("/tmp/libpin-amb", "w").write(amb + "\n" + "\n".join(pref[amb]))
PY
AMB=$(cat /tmp/libpin-amb | head -1)
mkrepo false 'true'
cat >"$R/third_party/toy/libpin.toml" <<P
name = "toy"
host_repo = "amb"
git_sha = "$AMB"
build = []
P
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -qiE 'ambiguous|cannot resolve' "$T/out" && ok "ambiguous short sha" || bad "ambiguous rc=$rc sha=$AMB $(tailout)"
rm -f /tmp/libpin-amb

# kit example smoke (seed-src + pick newest + stable sha256)
EX="$T/exkit"
rm -rf "$EX"
mkdir -p "$EX"
cp -a "$KIT/." "$EX/"
# drop tests dir pins if any
(cd "$EX" && ./fetch-deps --no-bwrap --no-landlock ro example files-pin) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "kit example+files-pin materialize" || bad "example ro rc=$rc $(tailout)"
(cd "$EX" && ./fetch-deps --no-bwrap --no-landlock build example) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'hello from third_party/example pin 0.0.1' "$EX/example/artifact/hello.bin" && ok "kit example build + stable artifact" || bad "example build rc=$rc $(tailout)"
(cd "$EX" && ./fetch-deps --no-bwrap --no-landlock ro) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '==> example' "$T/out" && ok "example default=false skipped in default set" || bad "example default rc=$rc $(tailout)"

# Host owned by another user: cannot chown without root.
# Manual: sudo chown ai-code:ai-code /path/to/host && ./fetch-deps --git-home ... ro <pin>
# Expected: permission/ownership is reported with David chmod/chown/setfacl lines;
# if git_https or git_ssh is set, materialize continues from that URL.

echo "passed $pass failed $fail"
[[ $fail -eq 0 ]]
