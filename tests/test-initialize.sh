#!/usr/bin/env bash
#
# Regression tests for loop/initialize.sh.
#
# Run: bash tests/test-initialize.sh
#
# The questions themselves are not driven here: a pty harness swallows the first line of piped
# input, so a test built on one asserts against the harness rather than the script. What is tested
# is everything that survives the questions: which file each scope writes, with what mode, that a
# re-run keeps the other keys, that the repository's file wins in --show, and that no secret ever
# reaches stdout.

set -euo pipefail

cd "$(dirname "$0")/.."

INIT="$(pwd -P)/loop/initialize.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %-56s got [%s] wanted [%s]\n' "$1" "$2" "$3" >&2; failures=$((failures + 1)); fi
}
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# Everything under $TMP: the global file through XDG_CONFIG_HOME, the repository file through a
# scratch repository. The developer's own settings are never touched.
export XDG_CONFIG_HOME="$TMP/xdg"
unset LOOP_ENV
GLOBAL="$TMP/xdg/engineering-loop/loop.env"
git init -q "$TMP/repo"
REPO_FILE="$TMP/repo/.git/engineering-loop/loop.env"
git -C "$TMP/repo" worktree add -q "$TMP/wt" -b side HEAD 2>/dev/null || {
  # An empty repository has no HEAD to branch from; give it one commit.
  git -C "$TMP/repo" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m base
  git -C "$TMP/repo" worktree add -q "$TMP/wt" -b side HEAD
}

# --- nothing configured ---------------------------------------------------------------------------

set +e
( cd "$TMP/repo" && "$INIT" --show ) > "$TMP/out" 2>&1
set -e
check "--show with nothing configured says both files are absent" "$(grep -c ': absent' "$TMP/out")" "2"
check "and reports the mode as unset" "$(grep -c '^effective LOOP_SANDBOX: unset$' "$TMP/out")" "1"

set +e
( cd "$TMP/repo" && "$INIT" < /dev/null ) > "$TMP/out" 2>&1
check "a non-interactive run refuses" "$?" "3"
set -e
check "and names the no-questions path" "$(grep -c -- '--host --repo' "$TMP/out")" "1"

set +e
( cd "$TMP/repo" && "$INIT" --host ) > "$TMP/out" 2>&1
check "--host without a scope is a usage error" "$?" "2"
( cd "$TMP" && "$INIT" --host --repo ) > "$TMP/out" 2>&1
check "--host --repo outside a repository is refused" "$?" "3"
( cd "$TMP/repo" && "$INIT" --nope ) > "$TMP/out" 2>&1
check "an unknown option is a usage error" "$?" "2"
set -e

# --- the two scopes ------------------------------------------------------------------------------

( cd "$TMP/repo" && "$INIT" --host --repo ) > "$TMP/out" 2>&1
check "--host --repo writes the repository's file under .git/" "$(sed -n 's/^LOOP_SANDBOX=//p' "$REPO_FILE")" "0"
check "the repository's file is 0600" "$(mode "$REPO_FILE")" "600"
check "the global file is not created by --repo" "$([ -e "$GLOBAL" ] && echo yes || echo no)" "no"
check "--host says where the sessions will run" "$(grep -c 'on this host' "$TMP/out")" "1"

( cd "$TMP/wt" && "$INIT" --show ) > "$TMP/out" 2>&1
check "a linked worktree sees the same repository file" "$(grep -c '^effective LOOP_SANDBOX: 0 (repo)$' "$TMP/out")" "1"

( cd "$TMP" && "$INIT" --host --global ) > "$TMP/out" 2>&1
check "--host --global writes the global file" "$(sed -n 's/^LOOP_SANDBOX=//p' "$GLOBAL")" "0"
check "the global file is 0600" "$(mode "$GLOBAL")" "600"
check "--host --global needs no repository" "$(grep -c 'on this host' "$TMP/out")" "1"

# --- precedence ----------------------------------------------------------------------------------

# Global says container, this repository says host: the repository wins, and --show says so.
"$INIT" --host --global > /dev/null 2>&1
awk '{ sub(/^LOOP_SANDBOX=.*/, "LOOP_SANDBOX=1"); print }' "$GLOBAL" > "$GLOBAL.tmp" && mv "$GLOBAL.tmp" "$GLOBAL"
( cd "$TMP/repo" && "$INIT" --show ) > "$TMP/out" 2>&1
check "the repository's file wins over the global one in --show" "$(grep -c '^effective LOOP_SANDBOX: 0 (repo)$' "$TMP/out")" "1"

rm -f "$REPO_FILE"
( cd "$TMP/repo" && "$INIT" --show ) > "$TMP/out" 2>&1
check "without a repository file the global one answers" "$(grep -c '^effective LOOP_SANDBOX: 1 (global)$' "$TMP/out")" "1"

# --- what a re-run keeps, and what --show never prints -----------------------------------------

cat > "$GLOBAL" <<'ENV'
# a comment that must survive
CLAUDE_CODE_OAUTH_TOKEN=
GH_TOKEN=github_pat_abc==/+xyz
LOOP_SANDBOX=1
ENV
chmod 600 "$GLOBAL"
"$INIT" --host --global > /dev/null 2>&1
check "--host keeps the other keys" \
  "$(awk -F= '$1 == "GH_TOKEN" { print substr($0, length("GH_TOKEN") + 2) }' "$GLOBAL")" "github_pat_abc==/+xyz"
check "a token containing = + / is stored verbatim" "$(grep -c '^GH_TOKEN=github_pat_abc==/+xyz$' "$GLOBAL")" "1"
check "the comment survives a rewrite" "$(grep -c '^# a comment' "$GLOBAL")" "1"

( cd "$TMP/repo" && "$INIT" --show ) > "$TMP/out" 2>&1
check "--show reports an empty key as EMPTY" "$(grep -c 'CLAUDE_CODE_OAUTH_TOKEN *EMPTY' "$TMP/out")" "1"
check "--show reports a filled key as set"   "$(grep -c 'GH_TOKEN *set' "$TMP/out")" "1"
check "--show never prints a secret" "$(grep -c 'github_pat' "$TMP/out")" "0"

# --- LOOP_ENV, the tests' single-file override ----------------------------------------------------

( cd "$TMP/repo" && LOOP_ENV="$TMP/one.env" "$INIT" --host ) > "$TMP/out" 2>&1
check "with LOOP_ENV, --host needs no scope and writes that file" "$(sed -n 's/^LOOP_SANDBOX=//p' "$TMP/one.env")" "0"
( cd "$TMP/repo" && LOOP_ENV="$TMP/one.env" "$INIT" --show ) > "$TMP/out" 2>&1
check "with LOOP_ENV, --show reads only that file" "$(grep -c "^effective LOOP_SANDBOX: 0 ($TMP/one.env)$" "$TMP/out")" "1"

# --- the template ---------------------------------------------------------------------------------

check "the committed template leaves the sandbox switch unanswered" \
  "$(grep -c '^LOOP_SANDBOX=$' loop/loop.env.dist)" "1"
check "the committed template carries no value" \
  "$(grep -cE '^(CLAUDE_CODE_OAUTH_TOKEN|GH_TOKEN)=.+' loop/loop.env.dist)" "0"

if [ "$failures" -ne 0 ]; then
  printf '\nFAIL: %d test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '\nOK -- initialize.sh\n'
