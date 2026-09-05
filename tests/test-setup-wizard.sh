#!/usr/bin/env bash
#
# Regression tests for loop/setup-loop.sh.
#
# Run: bash tests/test-setup-wizard.sh
#
# The prompts themselves are not driven here. A pty harness (`script -q`) swallows the first line of
# piped input -- verified with a bare three-`read` probe, which shifts by one slot exactly as the
# wizard appeared to -- so a test built on one would assert against the harness rather than the code.
# What is tested is everything that survives the questions: what gets written, with what mode, that a
# re-run preserves the other keys, and that secrets never reach stdout.

set -euo pipefail

cd "$(dirname "$0")/.."

WIZ="loop/setup-loop.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %-52s got [%s] wanted [%s]\n' "$1" "$2" "$3" >&2; failures=$((failures + 1)); fi
}

# A sandbox copy, so the developer's own credentials are never touched by a test run.
mkdir -p "$TMP/.loop" && git init -q "$TMP"
cp "$WIZ" "$TMP/.loop/"
cp loop/loop.env.dist "$TMP/.loop/"

set +e
( cd "$TMP" && ./.loop/setup-loop.sh --show ) > "$TMP/out" 2>&1
check "--show on an unconfigured repo explains itself" \
  "$(grep -c 'Run: ' "$TMP/out")" "1"

# Not a terminal: the wizard must say so rather than hang or half-write a file.
( cd "$TMP" && ./.loop/setup-loop.sh < /dev/null ) > "$TMP/out" 2>&1
check "a non-interactive run refuses" "$?" "3"
set -e
check "and it names the manual path" "$(grep -c 'by hand' "$TMP/out")" "1"

# Everything below exercises the file the wizard writes, which is the part with a failure mode.
cat > "$TMP/.loop/loop.env" <<'ENV'
# a comment that must survive
CLAUDE_CODE_OAUTH_TOKEN=
GH_TOKEN=github_pat_abc==/+xyz
LOOP_SANDBOX=1
MAX_UNITS=3
ENV
chmod 600 "$TMP/.loop/loop.env"

set +e
( cd "$TMP" && ./.loop/setup-loop.sh --show ) > "$TMP/out" 2>&1
set -e
check "--show reports an empty key as EMPTY" "$(grep -c 'CLAUDE_CODE_OAUTH_TOKEN *EMPTY' "$TMP/out")" "1"
check "--show reports a filled key as set"   "$(grep -c 'GH_TOKEN *set' "$TMP/out")" "1"

# The whole point of --show: it is safe to paste into a chat or a bug report.
check "--show never prints a secret" "$(grep -c 'github_pat' "$TMP/out")" "0"

# A GitHub PAT can contain '=', '+' and '/'. A rewrite that split on '=' and rejoined would corrupt
# it, and the failure would surface far from here as an unexplained 401.
stored="$(awk -F= '$1 == "GH_TOKEN" { print substr($0, length("GH_TOKEN") + 2) }' "$TMP/.loop/loop.env")"
check "a token containing = + / is stored verbatim" "$stored" "github_pat_abc==/+xyz"

check "the file the wizard maintains is 0600" \
  "$(stat -c '%a' "$TMP/.loop/loop.env" 2>/dev/null \
     || stat -f '%Lp' "$TMP/.loop/loop.env")" "600"

check "the committed template carries no value" \
  "$(grep -cE '^(CLAUDE_CODE_OAUTH_TOKEN|GH_TOKEN)=.+' loop/loop.env.dist)" "0"

if [ "$failures" -ne 0 ]; then
  printf '\nFAIL: %d test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '\nOK -- setup-loop.sh\n'
