#!/usr/bin/env bash
#
# Regression tests for loop/unit-size.sh and loop/comment-ratio.sh.
#
# Run: bash tests/test-unit-size.sh
#
# The fixture is a scratch repository built here rather than committed, because what is under test is
# a DIFF: a committed fixture would measure whatever the repository's own history did to it.
#
# Two properties carry most of the weight. Every exclusion is exercised in one commit, because an
# exclusion that stops matching does not fail -- it reports a larger number, and a unit that should
# have been split gets waved through. And the whole suite runs a second time from a subdirectory,
# because `:(exclude)` without `top` is cwd-relative and fails in exactly that silent way.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0

fixture() {
  repo="$TMP/repo"
  rm -rf "$repo"
  mkdir -p "$repo/.loop" "$repo/apps/api/src" "$repo/apps/web/messages" \
           "$repo/packages/api-client-ts/src" "$repo/.ai/specs" "$repo/deep/sub/dir"
  cp "$REPO_ROOT/loop/unit-size.sh" "$REPO_ROOT/loop/comment-ratio.sh" "$repo/.loop/"

  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  echo base > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  git -C "$repo" branch -f base-ref

  # Excluded: generated, locked, translated, and the spec itself. 1000 lines that must not be counted.
  seq 1 200 > "$repo/apps/api/openapi.json"
  seq 1 200 > "$repo/packages/api-client-ts/src/types.gen.ts"
  seq 1 200 > "$repo/pnpm-lock.yaml"
  seq 1 200 > "$repo/composer.lock"
  seq 1 200 > "$repo/apps/web/messages/es.json"
  # Counted for ctx, excluded from lines: 4 additions.
  printf 'a\nb\nc\nd\n' > "$repo/.ai/specs/some-spec.md"
  # Counted for ctx AND for lines: 3 additions.
  printf 'x\ny\nz\n' > "$repo/.ai/lessons.md"
  # An AGENTS.md at depth: 2 additions, both counted twice over (lines and ctx).
  printf 'p\nq\n' > "$repo/apps/api/AGENTS.md"

  # 10 added non-blank PHP lines, 2 of them prose. The docblock's /**, @param, @return and */
  # are type information; #[Attr] is an attribute, not a comment. -> 20%.
  cat > "$repo/apps/api/src/Thing.php" <<'PHP'
<?php
declare(strict_types=1);
/**
 * @param array<string, mixed> $rows
 * @return list<string>
 */
#[SomeAttribute]
// BR-XX01
/* a banner */
final class Thing {}
PHP
  # A file the classifier must ignore entirely: shell comments are carved out of the convention.
  printf '# a comment\n# another\ncode\n' > "$repo/deep/sub/dir/thing.sh"

  # The classifier is language-agnostic: the same rules on TypeScript, Python and Go. One prose
  # comment in each implementation file; the imports, signatures and bodies are code.
  mkdir -p "$repo/apps/web/src" "$repo/services/api" "$repo/cmd/tool"
  cat > "$repo/apps/web/src/widget.ts" <<'TS'
// The widget owns its own state.
import { useState } from "react";
export function widget(a: string): string {
  return a;
}
TS
  printf 'import { widget } from "./widget";\ntest("x", () => widget("a"));\n' > "$repo/apps/web/src/widget.test.ts"
  printf '# Handles the request end to end.\ndef handle(req):\n    return req\n' > "$repo/services/api/handler.py"
  printf '// Package main is the entry point.\npackage main\nfunc main() {}\n' > "$repo/cmd/tool/main.go"
  printf 'package main\nfunc TestMain(t *testing.T) {}\n' > "$repo/cmd/tool/main_test.go"

  # 6 test lines. Implementation and tests are reported apart, because a reviewer follows one line
  # by line and reads the other for coverage.
  mkdir -p "$repo/apps/api/tests/Unit"
  printf 'a\nb\nc\nd\ne\nf\n' > "$repo/apps/api/tests/Unit/ThingTest.php"

  git -C "$repo" add -A
  git -C "$repo" commit -qm feature
}

check() {
  name="$1"; dir="$2"; expected_exit="$3"; expected_out="$4"; shift 4
  set +e
  actual_out="$(cd "$dir" && env "$@" "$TMP/repo/.loop/unit-size.sh" base-ref 2>/dev/null)"
  actual_exit=$?
  set -e
  if [ "$actual_exit" != "$expected_exit" ] || [ "$actual_out" != "$expected_out" ]; then
    printf 'FAIL %-46s exit %s (wanted %s)\n       got:    %s\n       wanted: %s\n' \
      "$name" "$actual_exit" "$expected_exit" "$actual_out" "$expected_out" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'ok   %s\n' "$name"
}

fixture

# lines: 3 (.ai/lessons.md) + 2 (AGENTS.md) + 10 (Thing.php) + 3 (thing.sh) + 6 (ThingTest.php)
#        + 5 (widget.ts) + 2 (widget.test.ts) + 3 (handler.py) + 3 (main.go) + 2 (main_test.go) = 39
# tests: 6 (ThingTest.php) + 2 (widget.test.ts) + 2 (main_test.go) = 10
# files: lessons.md, AGENTS.md, Thing.php, thing.sh, ThingTest.php, widget.ts, widget.test.ts,
#        handler.py, main.go, main_test.go = 10
# ctx:   4 (.ai/specs) + 3 (.ai/lessons.md) + 2 (AGENTS.md) = 9
# comments: 5 prose (2 PHP, 1 TS, 1 Python, 1 Go) over 31 added lines in scope
#           (16 PHP + 7 TS + 3 Python + 5 Go) = 16%. The shell file is out of scope.
EXPECTED="39 lines (29 impl + 10 test), 10 files, 16% comments, 9 ctx"

# The host names its own generated paths; the lockfiles, `*.gen.*` and the spec are excluded by default.
HOST_EXCLUDES="apps/api/openapi.json apps/web/messages/*.json"

check "every exclusion holds, from the root" "$TMP/repo" 0 "$EXPECTED" LOOP_SIZE_EXCLUDES="$HOST_EXCLUDES"
check "every exclusion holds, from a subdirectory" "$TMP/repo/deep/sub/dir" 0 "$EXPECTED" LOOP_SIZE_EXCLUDES="$HOST_EXCLUDES"
# NO SIZE EVER GATES. The script reports; nothing here may turn a number back into an exit code:
# line count does not predict what a unit costs -- context does, driven by what a unit READS.
check "a large unit still exits 0" "$TMP/repo" 0 "$EXPECTED" LOOP_SIZE_EXCLUDES="$HOST_EXCLUDES" GUIDE_POST_LINES=1

printf 'LOOP_SIZE_EXCLUDES=%s\n' "$HOST_EXCLUDES" > "$TMP/repo/.loop/loop.env"
check "the excludes are read from .loop/loop.env" "$TMP/repo" 0 "$EXPECTED" IGNORE=1
rm -f "$TMP/repo/.loop/loop.env"

set +e
"$TMP/repo/.loop/unit-size.sh" no-such-ref >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" != 1 ]; then
  printf 'FAIL %-46s exit %s, wanted 1\n' "an unresolvable base fails closed" "$rc" >&2
  failures=$((failures + 1))
else
  printf 'ok   an unresolvable base fails closed\n'
fi

ratio="$(cd "$TMP/repo" && ./.loop/comment-ratio.sh base-ref)"
if [ "$ratio" != "16" ]; then
  printf 'FAIL %-46s got %s, wanted 16\n' "comment-ratio counts prose in every language" "$ratio" >&2
  failures=$((failures + 1))
else
  printf 'ok   comment-ratio counts prose in every language, not type info\n'
fi

if [ "$failures" -ne 0 ]; then
  printf '\nFAIL: %d test(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nOK -- unit-size.sh, comment-ratio.sh\n'
