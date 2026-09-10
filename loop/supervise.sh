#!/usr/bin/env bash
#
# Run the delivery loop until the unit is done, across the account's usage limit.
#
# delivery-loop.sh exits 5 when a session is refused for the usage limit. Nothing is wrong with the
# unit -- the next invocation continues the refused session -- but somebody has to make that next
# invocation, and until this script existed that somebody was the chat session: a background timer
# inside a chat, which dies with the chat and, on a host under memory pressure, is the first thing
# the harness reclaims. A run then sits paused until a human notices, which on an overnight run is
# breakfast. The wait belongs where the work already is, in the process launch.sh detaches.
#
# WHY IT POLLS RATHER THAN SLEEPS UNTIL THE RESET. The refusal carries a reset time in prose
# ("resets 3:20am (UTC)"), and parsing that means an am/pm and a timezone in every locale the CLI
# might phrase it for. Getting it wrong is worse than not reading it: too early spins, too late
# idles for hours. A refused session is a 429 that costs no tokens, so asking again on a fixed
# interval is both cheaper to be wrong about and shorter to write. The cost is bounded by the
# interval: the run resumes within LOOP_RESUME_WAIT of the reset, not at it.
#
# Usage: supervise.sh <spec-file>       -- from inside the repository, as delivery-loop.sh itself
#
# Exit: the delivery loop's own last exit code.

set -euo pipefail

SPEC="${1:-}"
[ -n "$SPEC" ] || { echo "usage: supervise.sh <spec-file>" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd -P)"
LOOP="$HERE/delivery-loop.sh"

# Seconds to wait before asking again after a refusal, and how many times to ask. The default pair
# covers a limit that resets up to six hours out, which is the longest the CLI hands out.
WAIT="${LOOP_RESUME_WAIT:-1800}"
MAX="${LOOP_RESUME_TRIES:-12}"

log() { printf 'delivery-loop: %s\n' "$*"; }

tries=0
while :; do
  rc=0
  "$LOOP" "$SPEC" || rc=$?

  # Anything but a usage-limit pause is this run's own answer: done, escalated, or refused at
  # pre-flight. The supervisor adds nothing to it.
  [ "$rc" = 5 ] || exit "$rc"

  tries=$((tries + 1))
  if [ "$tries" -ge "$MAX" ]; then
    log "still paused on the usage limit after $tries attempts; not trying again. Re-run launch.sh to continue"
    exit 5
  fi

  log "paused on the usage limit; continuing on my own in $((WAIT / 60))m (attempt $tries of $((MAX - 1)))"
  sleep "$WAIT"
  log "the usage-limit wait is over; continuing the unit"
done
