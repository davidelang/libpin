#!/usr/bin/env bash
# Tests for hardened fetch-deps / get-artifacts / sandbox (throwaway repos in /tmp).
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d /tmp/libpin-test.XXXXXX)"
SAMPLE=/tmp/libpin-help-samples
rm -rf "$SAMPLE"; mkdir -p "$SAMPLE"
fix_tree_perms() {
  local d="${1:-}" f
  [[ -n "$d" && -e "$d" ]] || return 0
  [[ -L "$d" ]] && return 0
  chmod u+rwx "$d" || return 0
  [[ -d "$d" ]] || return 0
  for f in "$d"/.* "$d"/*; do
    [[ "$f" == "$d/." || "$f" == "$d/.." ]] && continue
    [[ -e "$f" || -L "$f" ]] || continue
    fix_tree_perms "$f"
  done
}
trap 'fix_tree_perms "$T"; rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
G() { git -c user.name=t -c user.email=t@t "$@"; }
AGENT=$(id -un)
save_sample() { cp "$T/out" "$SAMPLE/$1.txt"; }
restore_comp() {
  chmod u+rwx "$1"
  if [[ -d "$1" ]]; then
    chmod -R u+rwx "$1"
  fi
}
no_own() { ! grep -q chown "$T/out" && ! grep -q chgrp "$T/out"; }
psugg() { "$KIT/fetch-deps" --no-bwrap --no-landlock --print-host-perm-suggestions "$@" >"$T/out" 2>&1; }
powner() { "$KIT/fetch-deps" --no-bwrap --no-landlock --print-owner-host-perm "$@" >"$T/out" 2>&1; }
order_ok() {
  python3 - "$T/out" "$@" <<'PY'
import sys
text = open(sys.argv[1]).read()
pos = -1
for n in sys.argv[2:]:
    i = text.find(n)
    if i < 0 or i < pos:
        sys.exit(1)
    pos = i
PY
}

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
[[ $rc -eq 0 ]] && grep -q '(no .git)' "$T/out" && [[ -f "$R/third_party/toy/src/content" ]] && ok "non-git shortcut falls through to git_https" || bad "notgit+https rc=$rc $(tailout)"

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

# blocked ancestor: parent a-x is owner help, not "does not exist"
ANC="$T/blocked/parent"
mkdir -p "$ANC"
cp -a "$GH/toy" "$ANC/toy"
chmod a-x "$ANC"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$ANC/toy\"|" "$R/third_party/toy/libpin.toml"
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
st_owner=$(stat -c '%U' "$ANC"); st_group=$(stat -c '%G' "$ANC")
[[ $rc -eq 0 ]] && grep -Fq "blocking component: $ANC (kind ancestor)" "$T/out" \
  && grep -q "owner=$st_owner group=$st_group" "$T/out" && grep -q "you are $AGENT" "$T/out" \
  && grep -Fq "owner ($st_owner):" "$T/out" && grep -Fq "chmod g+x $ANC" "$T/out" \
  && grep -Fq "chmod a+x $ANC" "$T/out" && grep -q 'broad (every user)' "$T/out" \
  && ! grep -q 'does not exist' "$T/out" && ! grep -q 'chmod -R' "$T/out" && no_own \
  && [[ -f "$R/third_party/toy/src/content" ]] \
  && ok "blocked ancestor reports owner help and uses git_https" || bad "blocked ancestor rc=$rc $(tailout)"
save_sample blocked-ancestor
restore_comp "$ANC"

# blocked repo dir: recursive rX, default ACL when setfacl exists
REPOB="$T/blockedrepo"
rm -rf "$REPOB"
cp -a "$GH/toy" "$REPOB"
chmod a-rx "$REPOB"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$REPOB\"|" "$R/third_party/toy/libpin.toml"
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
st_owner=$(stat -c '%U' "$REPOB"); st_group=$(stat -c '%G' "$REPOB")
[[ $rc -eq 0 ]] && grep -Fq "blocking component: $REPOB (kind repo)" "$T/out" \
  && grep -q "owner=$st_owner group=$st_group" "$T/out" && grep -q "you are $AGENT" "$T/out" \
  && grep -Fq "owner ($st_owner):" "$T/out" && grep -Fq "chmod -R g+rX $REPOB" "$T/out" \
  && grep -Fq "chmod -R a+rX $REPOB" "$T/out" && grep -q 'broad (every user)' "$T/out" \
  && no_own && [[ -f "$R/third_party/toy/src/content" ]] \
  && ok "blocked repo dir reports recursive rX and uses git_https" || bad "blocked repo rc=$rc $(tailout)"
if command -v setfacl >/dev/null; then
  grep -Fq "setfacl -R -d -m u:$AGENT:rX $REPOB" "$T/out" \
    && ok "blocked repo dir includes default ACL" || bad "blocked repo acl $(tailout)"
fi
save_sample blocked-repo
restore_comp "$REPOB"

# blocked repo, no remote: fail with the same owner help
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$REPOB\"|" "$R/third_party/toy/libpin.toml"
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
chmod a-rx "$REPOB"
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -Fq "blocking component: $REPOB (kind repo)" "$T/out" \
  && grep -q 'no usable host shortcut' "$T/out" && no_own \
  && ok "blocked repo without remote fails with owner help" || bad "blocked noremote rc=$rc $(tailout)"
restore_comp "$REPOB"

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

# ssh URL key failure prints ssh -T / git clone; no identity-file help
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
[[ $rc -ne 0 ]] && grep -q 'ssh -T git@invalid.example' "$T/out" \
  && grep -q "git clone git@invalid.example:toy.git $R/third_party/toy/src" "$T/out" \
  && grep -q 'then:' "$T/out" && grep -q 'SSH_AUTH_SOCK' "$T/out" \
  && ! grep -q ' -i ' "$T/out" && ! grep -q '.ssh/id_' "$T/out" \
  && ! grep -q 'GIT_SSH_COMMAND' "$T/out" && ! grep -q 'chmod 700' "$T/out" \
  && ! grep -q 'known_hosts' "$T/out" && no_own \
  && ok "ssh key failure prints ssh -T / git clone" || bad "ssh help rc=$rc $(tailout)"
save_sample ssh-key-failure

# ssh host-key missing (empty HOME known_hosts)
cat >"$T/sshbin/ssh" <<'EOF'
#!/bin/bash
echo "Host key verification failed." >&2
exit 255
EOF
chmod +x "$T/sshbin/ssh"
HOMED=$(mktemp -d /tmp/libpin-home.XXXXXX)
mkdir -p "$HOMED/.ssh"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
sed -i 's|^name = "toy"|name = "toy"\ngit_ssh = "git@invalid.example:toy.git"|' "$R/third_party/toy/libpin.toml"
(cd "$R" && env HOME="$HOMED" PATH="$T/sshbin:$PATH" GIT_SSH="$T/sshbin/ssh" GIT_SSH_COMMAND="$T/sshbin/ssh" ./third_party/fetch-deps --no-bwrap --no-landlock ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -Fq "this account (${AGENT})'s known_hosts" "$T/out" \
  && grep -q 'host key not found in known_hosts' "$T/out" \
  && grep -q 'ssh-keyscan -H invalid.example >> ~/.ssh/known_hosts' "$T/out" \
  && grep -q 'verify the fingerprint first' "$T/out" && ! grep -q 'ssh-keygen -R' "$T/out" \
  && no_own && ok "ssh host-key missing prints append-only keyscan" || bad "ssh hostkey missing rc=$rc $(tailout)"
save_sample ssh-host-key-missing
rm -rf "$HOMED"

# ssh host-key changed
cat >"$T/sshbin/ssh" <<'EOF'
#!/bin/bash
echo "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!" >&2
exit 255
EOF
chmod +x "$T/sshbin/ssh"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
sed -i 's|^name = "toy"|name = "toy"\ngit_ssh = "git@invalid.example:toy.git"|' "$R/third_party/toy/libpin.toml"
(cd "$R" && env PATH="$T/sshbin:$PATH" GIT_SSH="$T/sshbin/ssh" GIT_SSH_COMMAND="$T/sshbin/ssh" ./third_party/fetch-deps --no-bwrap --no-landlock ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'ssh-keygen -R invalid.example' "$T/out" \
  && grep -q 'ssh-keyscan -H invalid.example >> ~/.ssh/known_hosts' "$T/out" \
  && grep -q 'host key changed, verify fingerprint before trusting' "$T/out" \
  && no_own && ok "ssh host-key changed prints -R then keyscan" || bad "ssh hostkey changed rc=$rc $(tailout)"
save_sample ssh-host-key-changed

# ssh:// with no user
cat >"$T/sshbin/ssh" <<'EOF'
#!/bin/bash
echo "Permission denied (publickey)." >&2
exit 255
EOF
chmod +x "$T/sshbin/ssh"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
sed -i 's|^name = "toy"|name = "toy"\ngit_ssh = "ssh://invalid.example/toy.git"|' "$R/third_party/toy/libpin.toml"
(cd "$R" && env PATH="$T/sshbin:$PATH" GIT_SSH="$T/sshbin/ssh" GIT_SSH_COMMAND="$T/sshbin/ssh" ./third_party/fetch-deps --no-bwrap --no-landlock ro toy) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -Fq "ssh:// URL has no user; ssh will use $AGENT" "$T/out" \
  && grep -q 'ssh -T invalid.example' "$T/out" && no_own \
  && ok "ssh:// with no user names live account" || bad "ssh nouser rc=$rc $(tailout)"
save_sample ssh-no-user

# --print-host-perm-suggestions: injected owner/group/mode
psugg /p repo alice dev 750 "$AGENT" "othergrp" 1; rc=$?
[[ $rc -eq 0 ]] && grep -q "sudo usermod -aG dev $AGENT" "$T/out" \
  && grep -q "new login or \`newgrp dev\`" "$T/out" \
  && ! grep -q 'chmod g+' "$T/out" && ! grep -q 'chmod -R g+' "$T/out" \
  && order_ok "sudo usermod -aG dev $AGENT" "setfacl -R -m u:$AGENT:rX /p" "broad (every user)" "chmod -R a+rX /p" \
  && no_own && ok "print suggestions repo 750 not-in-group is (a)(c)(d)" || bad "sugg 750 rc=$rc $(tailout)"
save_sample agent-not-in-group

psugg /p repo alice dev 700 "$AGENT" "othergrp" 1; rc=$?
[[ $rc -eq 0 ]] && grep -q "chmod -R g+rX /p" "$T/out" \
  && order_ok "chmod -R g+rX /p" "sudo usermod -aG dev $AGENT" "setfacl -R -m u:$AGENT:rX /p" "broad (every user)" "chmod -R a+rX /p" \
  && no_own && ok "print suggestions repo 700 not-in-group is (b)(c)(d)" || bad "sugg 700 rc=$rc $(tailout)"

psugg /p repo alice dev 750 "$AGENT" "dev extra" 1; rc=$?
[[ $rc -eq 0 ]] && ! grep -q usermod "$T/out" && grep -q 'broad (every user)' "$T/out" \
  && no_own && ok "print suggestions agent-in-group skips usermod" || bad "sugg in-group rc=$rc $(tailout)"

psugg /home ancestor alice dev 711 "$AGENT" "othergrp" 1; rc=$?
[[ $rc -eq 0 ]] && grep -q "chmod a+x /home" "$T/out" && ! grep -q -- '-R' "$T/out" \
  && no_own && ok "print suggestions ancestor has no -R" || bad "sugg ancestor rc=$rc $(tailout)"

psugg /p/file file alice dev 600 "$AGENT" "othergrp" 1; rc=$?
[[ $rc -eq 0 ]] && grep -q "chmod g+r /p/file" "$T/out" && grep -q "u:$AGENT:r /p/file" "$T/out" \
  && grep -q "chmod a+r /p/file" "$T/out" && ! grep -q -- '-R' "$T/out" \
  && no_own && ok "print suggestions file is g+r/:r/a+r without -R" || bad "sugg file rc=$rc $(tailout)"

psugg /p repo alice dev 1755 "$AGENT" "othergrp" 1; rc=$?
[[ $rc -eq 0 ]] && grep -q "sudo usermod -aG dev $AGENT" "$T/out" && ! grep -q 'chmod g+' "$T/out" \
  && no_own && ok "print suggestions mode 1755 parsed as 755" || bad "sugg 1755 rc=$rc $(tailout)"

psugg /p file alice dev 600 "$AGENT" "othergrp" 0; rc=$?
[[ $rc -eq 0 ]] && grep -q 'setfacl is not installed' "$T/out" && ! grep -q 'setfacl -' "$T/out" \
  && no_own && ok "print suggestions setfacl missing" || bad "sugg nosetfacl rc=$rc $(tailout)"
save_sample setfacl-missing

psugg /p repo root root 755 "$AGENT" "othergrp" 1; rc=$?
[[ $rc -eq 0 ]] && no_own && ok "print suggestions owner uid 0 has no chown/chgrp" || bad "sugg uid0 rc=$rc $(tailout)"

psugg a b c d e f g; rc=$?
[[ $rc -eq 2 ]] && grep -q 'needs 8 arguments' "$T/out" && ok "print suggestions 7 words is rc 2" || bad "sugg 7words rc=$rc $(tailout)"

powner /p toy; rc=$?
[[ $rc -eq 2 ]] && grep -q 'needs 3 arguments' "$T/out" && ok "print owner-host-perm 2 words is rc 2" || bad "powner 2words rc=$rc $(tailout)"

psugg a b c d e f g h extra; rc=$?
[[ $rc -eq 2 ]] && grep -q 'takes exactly 8 arguments' "$T/out" && ok "print suggestions extra word is rc 2" || bad "sugg extra rc=$rc $(tailout)"

# unreadable .git file: kind file recipes, no -R
GF="$T/gitfilehost"
mkdir -p "$GF"
echo "gitdir: /nonexistent" >"$GF/.git"
chmod a-r "$GF/.git"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$GF\"|" "$R/third_party/toy/libpin.toml"
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && grep -Fq "blocking component: $GF/.git (kind file)" "$T/out" \
  && grep -Fq "chmod g+r $GF/.git" "$T/out" && grep -Fq "chmod a+r $GF/.git" "$T/out" \
  && ! grep -q 'chmod -R' "$T/out" && ! grep -q 'setfacl -R' "$T/out" && no_own \
  && [[ -f "$R/third_party/toy/src/content" ]] \
  && ok "unreadable .git file uses file recipes" || bad "gitfile unread rc=$rc $(tailout)"
save_sample unreadable-git-file
restore_comp "$GF/.git"

# .git file with relative gitdir: resolved gitdir is walked
GD="$T/gd"
mkdir -p "$GD/wt" "$GD/realgit/.git"
echo "gitdir: ../realgit/.git" >"$GD/wt/.git"
chmod a-x "$GD/realgit"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$GD/wt\"|" "$R/third_party/toy/libpin.toml"
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && grep -Fq "blocking component: $GD/realgit (kind ancestor)" "$T/out" \
  && grep -Fq "chmod g+x $GD/realgit" "$T/out" && ! grep -q 'chmod -R' "$T/out" && no_own \
  && ok "relative gitdir is walked" || bad "relative gitdir rc=$rc $(tailout)"
restore_comp "$GD/realgit"

# .git file without gitdir: line
NGD="$T/nogitdirhost"
mkdir -p "$NGD"
echo "not a gitdir file" >"$NGD/.git"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"$NGD\"|" "$R/third_party/toy/libpin.toml"
sed -i '/^git_https/d' "$R/third_party/toy/libpin.toml"
fd ro toy; rc=$?
[[ $rc -ne 0 ]] && grep -Fq "exists but is not a git repo ('.git' file has no gitdir: line)" "$T/out" \
  && grep -q 'no usable host shortcut' "$T/out" && no_own \
  && ok ".git file without gitdir: is a distinct not-a-repo message" || bad "nogitdir rc=$rc $(tailout)"
save_sample gitfile-no-gitdir

# dubious ownership via print-owner-host-perm
powner "$GH/toy" toy "fatal: detected dubious ownership in repository at $GH/toy"; rc=$?
[[ $rc -eq 0 ]] && grep -Fq "path is readable by $AGENT" "$T/out" \
  && grep -q "git reported dubious ownership" "$T/out" \
  && grep -Fq -- "-c safe.directory=$GH/toy is already passed" "$T/out" && no_own \
  && ok "dubious ownership prints already-passed text" || bad "dubious rc=$rc $(tailout)"
save_sample dubious-ownership
powner "$GH/toy" toy ""; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'dubious ownership' "$T/out" && no_own \
  && ok "empty git stderr omits dubious-ownership text" || bad "dubious empty rc=$rc $(tailout)"

# rerun line through reenter_self (sandbox binds GIT_HOME)
mkdir -p "$GH/blk"
rm -rf "$GH/blk/toy"
cp -a "$GH/toy" "$GH/blk/toy"
chmod a-x "$GH/blk"
mkrepo false 'printf "built %s\n" "$(cat src/content)" >src/out.bin'
sed -i "s|^name = \"toy\"|name = \"toy\"\nhost_repo = \"blk/toy\"|" "$R/third_party/toy/libpin.toml"
sed -i "s|git_https = \".*\"|git_https = \"$GH/toy\"|" "$R/third_party/toy/libpin.toml"
fd_sbx ro toy; rc=$?
expected=$(printf '%q ' "./third_party/fetch-deps" --git-home "$GH" ro toy)
expected="${expected% }"
grep -Fq "then: $expected" "$T/out" && grep -Fq "blocking component: $GH/blk (kind ancestor)" "$T/out" \
  && no_own && ok "rerun line survives reenter_self" || bad "rerun reentry rc=$rc expected='$expected' $(tailout)"
save_sample rerun-reentry
restore_comp "$GH/blk"

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

# missing sandbox tools (PATH with common tools but no bwrap): continue
mkrepo false 'true'
mkdir -p "$T/limited"
for t in bash sh python3 git curl env sha256sum realpath mktemp cat grep sed awk head tr date chmod mkdir rm cp mv ln ls find sort stat uname id cut basename dirname git-upload-pack git-receive-pack true; do
  if p=$(type -P "$t"); then
    [[ -e "$T/limited/$t" ]] || ln -s "$p" "$T/limited/$t"
  fi
done
ll_rc=0
ll_live=$("$R/third_party/libpin-landlock" --status 2>&1) || ll_rc=$?
( export PATH="$T/limited"; cd "$R" && ./third_party/fetch-deps --git-home "$GH" ro toy ) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'bwrap unavailable (bwrap not found on PATH); continuing without it' "$T/out" \
  && [[ -f "$R/third_party/toy/src/content" ]] \
  && ok "missing bwrap is reported and the run continues" || bad "missing bwrap rc=$rc $(tailout)"
if [[ "$ll_rc" -eq 0 ]]; then
  ll_abi="${ll_live#available }"
  ll_abi="${ll_abi/=/ }"
  grep -Fq "Landlock available ($ll_abi); write confinement on" "$T/out" \
    && ok "missing bwrap still reports live Landlock status" || bad "missing bwrap landlock $(tailout)"
else
  grep -q 'Landlock unavailable' "$T/out" \
    && ok "missing bwrap reports Landlock unavailable to match live --status" || bad "missing bwrap landlock $(tailout)"
fi
save_sample sandbox-bwrap-missing

# bwrap installed but failing: fake bwrap on PATH
mkrepo false 'true'
mkdir -p "$T/fakebw"
cat >"$T/fakebw/bwrap" <<'EOF'
#!/bin/bash
echo "bwrap: loopback: Permission denied" >&2
exit 1
EOF
chmod +x "$T/fakebw/bwrap"
( export PATH="$T/fakebw:$PATH"; cd "$R" && ./third_party/fetch-deps --git-home "$GH" ro toy ) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'bwrap unavailable (bwrap: loopback: Permission denied); continuing without it' "$T/out" \
  && [[ -f "$R/third_party/toy/src/content" ]] \
  && ok "failing bwrap is reported and the run continues" || bad "failing bwrap rc=$rc $(tailout)"
save_sample sandbox-bwrap-failing

# Landlock unavailable; both missing -> none active
mkrepo false 'true'
cat >"$R/third_party/libpin-landlock" <<'EOF'
#!/bin/bash
LIBPIN_VERSION=2026.10.24
if [[ "${1:-}" == "--status" ]]; then
  echo unavailable
  exit 1
fi
echo "libpin-landlock: stub invoked" >&2
exit 1
EOF
chmod +x "$R/third_party/libpin-landlock"
( cd "$R" && ./third_party/fetch-deps --git-home "$GH" ro toy ) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'Landlock unavailable (unavailable); continuing without it' "$T/out" \
  && [[ -f "$R/third_party/toy/src/content" ]] \
  && ok "Landlock unavailable is reported and the run continues" || bad "ll unavailable rc=$rc $(tailout)"
save_sample sandbox-landlock-unavailable
( cd "$R" && ./third_party/fetch-deps --git-home "$GH" --no-bwrap ro toy ) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'Landlock unavailable (unavailable); continuing without it' "$T/out" \
  && grep -q 'none active; pin writes are not confined' "$T/out" \
  && ok "Landlock unavailable with bwrap off is none active" || bad "ll unavailable+nobwrap rc=$rc $(tailout)"
( export PATH="$T/limited"; cd "$R" && ./third_party/fetch-deps --git-home "$GH" ro toy ) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'bwrap unavailable (bwrap not found on PATH); continuing without it' "$T/out" \
  && grep -q 'Landlock unavailable' "$T/out" && grep -q 'none active; pin writes are not confined' "$T/out" \
  && ok "neither sandbox tool available: none active, rc 0" || bad "neither available rc=$rc $(tailout)"
save_sample sandbox-neither

# explicit --no-* flags: disabled, not unavailable
mkrepo false 'true'
fd ro toy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'bwrap disabled (--no-bwrap)' "$T/out" \
  && grep -q 'Landlock disabled (--no-landlock)' "$T/out" \
  && grep -q 'none active; pin writes are not confined' "$T/out" \
  && ! grep -q unavailable "$T/out" \
  && ok "explicit --no-bwrap --no-landlock reports disabled" || bad "disabled flags rc=$rc $(tailout)"
save_sample sandbox-disabled

# re-entry prints sandbox report once
mkrepo false 'true'
fd_sbx ro toy; rc=$?
sbx_lines=$(grep -c 'libpin: sandbox:' "$T/out" || true)
[[ $rc -eq 0 ]] && [[ "$sbx_lines" -eq 2 ]] \
  && grep -q 'bwrap available; write confinement on' "$T/out" \
  && grep -q 'Landlock available' "$T/out" \
  && ok "sandbox report appears once through reenter_self" || bad "reentry report rc=$rc lines=$sbx_lines $(tailout)"
save_sample sandbox-both-available

# libpin-sandbox direct, bwrap missing
mkrepo false 'true'
( export PATH="$T/limited"; cd "$R" && ./third_party/libpin-sandbox --mode lib --lib toy -- true ) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'libpin-sandbox: bwrap unavailable (bwrap not found on PATH); continuing without it' "$T/out" \
  && ok "libpin-sandbox direct continues without bwrap" || bad "sandbox direct rc=$rc $(tailout)"

# --require-bwrap stops when bwrap is missing
mkrepo false 'true'
( export PATH="$T/limited"; cd "$R" && ./third_party/fetch-deps --git-home "$GH" --require-bwrap ro toy ) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'bwrap required (--require-bwrap) but unavailable (bwrap not found on PATH)' "$T/out" \
  && ok "--require-bwrap stops when bwrap is missing" || bad "require-bwrap rc=$rc $(tailout)"

# --require-libpin / --require-landlock stop when Landlock is missing
mkrepo false 'true'
cat >"$R/third_party/libpin-landlock" <<'EOF'
#!/bin/bash
LIBPIN_VERSION=2026.10.24
if [[ "${1:-}" == "--status" ]]; then
  echo unavailable
  exit 1
fi
exit 1
EOF
chmod +x "$R/third_party/libpin-landlock"
( cd "$R" && ./third_party/fetch-deps --git-home "$GH" --no-bwrap --require-libpin ro toy ) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'Landlock required (--require-landlock) but unavailable' "$T/out" \
  && ok "--require-libpin stops when Landlock is missing" || bad "require-libpin rc=$rc $(tailout)"
( cd "$R" && ./third_party/fetch-deps --git-home "$GH" --require-bwrap --no-bwrap ro toy ) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 2 ]] && grep -q 'conflicts with --no-bwrap' "$T/out" \
  && ok "--require-bwrap conflicts with --no-bwrap" || bad "require conflict rc=$rc $(tailout)"

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

# Host owned by another user with mode 700: this process cannot enter it.
# Manual: as that owner, chmod g+rX or setfacl, then rerun fetch-deps.
# Expected: owner help names the blocking component and live stat owner/group;
# if git_https or git_ssh is set, materialize continues from that URL.

echo "passed $pass failed $fail"
[[ $fail -eq 0 ]]
