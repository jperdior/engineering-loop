#!/usr/bin/env bash
#
# Regression tests for loop/supervise.sh.
#
# Run: bash tests/test-supervise.sh
#
# The supervisor's whole job is what it does with the delivery loop's exit code, so the loop itself
# is a stub: each case copies supervise.sh into a throwaway directory and puts a `delivery-loop.sh`
# beside it that returns a scripted sequence of codes. Nothing here runs a real loop, a container or
# a session, and the waits are set to zero so a retry case costs no wall clock.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd -P)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
CASE=""
pass() { printf '  ok   %s\n' "$CASE"; }
fail() { printf '  FAIL %s\n     %s\n' "$CASE" "$1"; failures=$((failures + 1)); }

# A throwaway loop directory: the real supervisor, and a stub loop that exits the codes named in $1,
# one per invocation, repeating the last one forever.
stage() {
  local dir="$TMP/$1"; shift
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$REPO_ROOT/loop/supervise.sh" "$dir/supervise.sh"
  printf '%s\n' "$@" > "$dir/codes"
  cat > "$dir/delivery-loop.sh" <<'STUB'
#!/usr/bin/env bash
# The stub loop: read the call count, echo the spec it was handed, exit the nth scripted code.
d="$(cd "$(dirname "$0")" && pwd -P)"
n=0; [ ! -f "$d/calls" ] || n="$(cat "$d/calls")"
n=$((n + 1)); echo "$n" > "$d/calls"
echo "$1" >> "$d/specs"
code="$(sed -n "${n}p" "$d/codes")"
[ -n "$code" ] || code="$(tail -1 "$d/codes")"
echo "delivery-loop: stub call $n exiting $code"
exit "$code"
STUB
  chmod +x "$dir/delivery-loop.sh"
  printf '%s' "$dir"
}

# Run a staged supervisor with no waiting between attempts.
run_sup() {
  local dir="$1"; shift
  ( cd "$dir" && LOOP_RESUME_WAIT=0 LOOP_RESUME_TRIES="${TRIES:-12}" \
      ./supervise.sh spec.md > "$dir/out" 2> "$dir/err" )
}

calls() { cat "$1/calls" 2>/dev/null || echo 0; }

echo "supervise.sh"

# A run that never hits the limit must be exactly one run: a supervisor that retries a success would
# build the unit twice.
CASE="a finished run is one call and exit 0"
d="$(stage finished 0)"
if run_sup "$d" && [ "$(calls "$d")" = 1 ]; then pass
else fail "exit $?, calls $(calls "$d")"; fi

# 4 and 3 are answers, not pauses: an escalation needs a human and a pre-flight refusal needs a fix.
# Retrying either burns sessions against a state that will not change on its own.
for code in 4 3 2; do
  CASE="exit $code is passed straight through, not retried"
  d="$(stage "pass$code" "$code")"
  set +e; run_sup "$d"; rc=$?; set -e
  if [ "$rc" = "$code" ] && [ "$(calls "$d")" = 1 ]; then pass
  else fail "exit $rc, calls $(calls "$d")"; fi
done

# The point of the script: a usage-limit pause is waited out and continued without anyone asking.
CASE="a usage-limit pause is retried until the unit finishes"
d="$(stage retry 5 5 0)"
if run_sup "$d" && [ "$(calls "$d")" = 3 ]; then pass
else fail "exit $?, calls $(calls "$d")"; fi

CASE="the retry says so in the log, with the delivery-loop prefix the watcher greps"
if grep -q '^delivery-loop: paused on the usage limit; continuing on my own' "$d/out" \
   && grep -q '^delivery-loop: the usage-limit wait is over' "$d/out"; then pass
else fail "$(cat "$d/out")"; fi

# The spec is what the loop is handed, so a retry that dropped it would start a different unit.
CASE="every retry is handed the same spec"
if [ "$(sort -u "$d/specs" | tr -d '\n')" = "spec.md" ] && [ "$(grep -c . "$d/specs")" = 3 ]; then pass
else fail "$(tr '\n' ' ' < "$d/specs")"; fi

# An account limited for longer than the supervisor is willing to wait must stop and say so, rather
# than spin against a 429 until the session cap or the user's patience runs out.
CASE="the retries are bounded and the last word is exit 5"
d="$(stage giveup 5)"
set +e; TRIES=3 run_sup "$d"; rc=$?; set -e
if [ "$rc" = 5 ] && [ "$(calls "$d")" = 3 ] \
   && grep -q '^delivery-loop: still paused on the usage limit after 3 attempts' "$d/out"; then pass
else fail "exit $rc, calls $(calls "$d"): $(tail -1 "$d/out")"; fi

CASE="no spec is a usage error, not a run"
d="$(stage nospec 0)"
set +e; ( cd "$d" && ./supervise.sh > "$d/out" 2> "$d/err" ); rc=$?; set -e
if [ "$rc" = 2 ] && [ "$(calls "$d")" = 0 ] && grep -q 'usage: supervise.sh' "$d/err"; then pass
else fail "exit $rc, calls $(calls "$d")"; fi

# The supervisor only matters if it is what gets detached; launching the loop directly puts the wait
# back in the chat, which is the failure this script was written to end.
CASE="launch.sh detaches the supervisor, not the loop"
# shellcheck disable=SC2016  # the pattern is grep's, not the shell's: $LOOP_DIR is matched literally
if grep -q 'nohup bash -c .*"\$LOOP_DIR/supervise.sh" "\$SPEC"' "$REPO_ROOT/loop/launch.sh" \
   && ! grep -q 'nohup bash -c .*delivery-loop.sh' "$REPO_ROOT/loop/launch.sh"; then pass
else fail "launch.sh does not detach supervise.sh"; fi

# The bell and its notifier were removed: they were macOS-shaped, silent on the detached runs that
# need them most, and a second thing to keep working.
CASE="no bell and no notifier hook survive"
if ! grep -rqE 'DELIVERY_LOOP_BELL|DELIVERY_LOOP_NOTIFY|attention\(\)' \
     "$REPO_ROOT/loop" "$REPO_ROOT/README.md"; then pass
else fail "$(grep -rlE 'DELIVERY_LOOP_BELL|DELIVERY_LOOP_NOTIFY|attention\(\)' "$REPO_ROOT/loop" "$REPO_ROOT/README.md" | tr '\n' ' ')"; fi

echo
if [ "$failures" = 0 ]; then echo "all supervise.sh cases pass"; else echo "$failures failing"; exit 1; fi
