#!/usr/bin/env bash
#
# Build a spec's delivery unit unattended: one fresh `claude -p` per spec PHASE, on one branch, then
# one final session for the review, and one PR.
#
# The loop NEVER merges. It stops after opening the PR; a human merges it.
#
# Usage:
#   delivery-loop.sh <spec-file> [--dry-run] [--force-unlock]
#
#   --dry-run       run pre-flight, print the unit, its branch, its phases and the bounds, create
#                   nothing. Run this first against any real spec.
#   --force-unlock  take a lock this script refuses to reclaim on its own.
#
# Settings, all environment variables, read from .loop/loop.env (see .loop/loop.env.dist):
#
#   LOOP_GATES="make lint;make test"  the host's gates, run from the repo root in this order once the
#                                     closing session says OK. The sessions run the same list through
#                                     /run-gates; this is the loop's own check on the host.
#
#   LOOP_MODEL=opus              the model every build session runs on. The PR-opening session runs
#                                on sonnet: it reads a diff and fills a template.
#   MAX_SESSIONS=<phases>+2      sessions per invocation before the unit is declared non-converging.
#   UNIT_TIMEOUT=7200            seconds per session, enforced by timeout(1).
#   SESSION_CONTEXT_ALARM=150000 a session whose peak context exceeds this is reported. It is a
#                                reading, not an instruction: a session cannot observe its own
#                                context, so nothing in the prompt asks it to.
#
# There is no budget. The unit is built until it is done. A session refused for the account's usage
# limit PAUSES the run (exit 5) rather than escalating: nothing is wrong with the unit, and re-running
# the same command once the limit resets continues from the first unticked phase.
#
# Exit: 0 the unit is done or nothing is owed, 2 usage, 3 pre-flight or lock failure, 4 an escalation,
#       5 paused on the usage limit.

set -euo pipefail

# RUN FROM A SNAPSHOT OF THIS SCRIPT, NOT FROM THE FILE ITSELF.
#
# Bash reads a script incrementally as it executes, so editing this file while a run is in flight
# makes it read a TORN file: the next line it reaches is whatever the editor left at that byte
# offset. A run lasts an hour, and not editing the harness for an hour is not a rule anyone keeps,
# so the script copies itself once and re-executes from the copy, which no editor is writing to.
if [ -z "${DELIVERY_LOOP_SNAPSHOT:-}" ]; then
  __snap="$(mktemp -t delivery-loop.XXXXXX)"
  cat "$0" > "$__snap"
  chmod +x "$__snap"
  # The snapshot lives in a temp dir, so `dirname $0` no longer finds the repository. The real
  # location is carried across the exec; everything downstream resolves ROOT from it.
  DELIVERY_LOOP_ORIGIN="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
  export DELIVERY_LOOP_ORIGIN
  export DELIVERY_LOOP_SNAPSHOT="$__snap"
  exec "$__snap" "$@"
fi
# Covers every exit before `trap teardown EXIT` replaces this one; teardown removes it after that.
trap 'rm -f "${DELIVERY_LOOP_SNAPSHOT:-}"' EXIT

SPEC=""
DRY_RUN=0
FORCE_UNLOCK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1 ;;
    --force-unlock) FORCE_UNLOCK=1 ;;
    -*)             echo "delivery-loop: unknown option '$1'" >&2; exit 2 ;;
    *)              [ -z "$SPEC" ] || { echo "delivery-loop: one spec file, not two" >&2; exit 2; }; SPEC="$1" ;;
  esac
  shift
done

if [ -z "$SPEC" ]; then
  echo "usage: delivery-loop.sh <spec-file> [--dry-run] [--force-unlock]" >&2
  exit 2
fi

# The engine lives in <repo>/.loop/. The repository root is resolved through git rather than by
# counting `..` so the engine can be vendored anywhere a host puts it.
LOOP_DIR="$(cd "$(dirname "${DELIVERY_LOOP_ORIGIN:-$0}")" && pwd -P)"
cd "$(git -C "$LOOP_DIR" rev-parse --show-toplevel)"
ROOT="$(pwd -P)"

# The tick is written from INSIDE the unit's worktree, so the spec path has to be repo-root-relative
# to land on the unit's branch. An absolute path would have `record` edit the main checkout's copy
# and then fail to stage it, leaving the PR open and the ledger unticked.
case "$SPEC" in
  "$ROOT"/*) SPEC="${SPEC#"$ROOT"/}" ;;
  /*) echo "delivery-loop: the spec must live inside $ROOT" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------- configuration file
#
# One place for the loop's settings and its two credentials, instead of a token in ~/.zshrc and a
# flag on every invocation. `.loop/loop.env.dist` is the committed template; the file it is copied
# to is gitignored.
#
# THE SHELL WINS. A value already exported is never overwritten, so a one-off
# `LOOP_MODEL=sonnet .loop/delivery-loop.sh …` still overrides the file -- the file is where
# the settings LIVE, not a thing that fights the command line.
#
# GH_TOKEN belongs here rather than in a shell profile: it overrides `gh auth switch`, so a global
# one silently hijacks every interactive gh command in a repository worked with two accounts.
load_env_file() {
  local f="$LOOP_DIR/loop.env" line key val
  [ -f "$f" ] || return 0

  # It holds tokens. Readable by anyone is worth a word, not a refusal.
  # `stat -c` on GNU, `stat -f` on BSD/macOS; GNU first, because BSD's -c fails while GNU's -f answers; the mode is what matters, not the listing format.
  case "$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)" in
    ?[1-7]?|??[1-7]) printf 'delivery-loop: %s is readable beyond you; chmod 600 it\n' "$f" >&2 ;;
  esac

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    [ -z "${!key:-}" ] || continue
    export "$key=$val"
  done < "$f"
}

load_env_file

# A SESSION IS ONE PHASE, AND THAT IS WHAT BOUNDS ITS CONTEXT.
#
# A session cannot see how many tokens its context holds, so a token budget in the prompt is an
# instruction with nothing to measure against and is not obeyed. A phase is observable from
# outside: the loop reads the spec's `## Progress` checklist on the branch, hands the next unticked
# phase to a fresh process, and checks the tick when that process exits. Context resets because the
# process is new; the work survives because the branch is not.
#
# SESSION_CONTEXT_ALARM is a reading on the telemetry, not a limit: a session whose recorded peak
# exceeds it is reported, which is the evidence that a phase is cut too large.
LOOP_GATES="${LOOP_GATES:-make lint;make test}"
LOOP_MODEL="${LOOP_MODEL:-opus}"
PR_MODEL="sonnet"
SESSION_CONTEXT_ALARM="${SESSION_CONTEXT_ALARM:-150000}"
MAX_SESSIONS="${MAX_SESSIONS:-}"

UNIT_TIMEOUT="${UNIT_TIMEOUT:-7200}"

STATE_DIR="$LOOP_DIR/state"
LOCK="$STATE_DIR/lock"
LEDGER="$STATE_DIR/ledger.$$"
PHASES="$STATE_DIR/phases.$$"
WORKTREES="$ROOT/.claude/worktrees"
RUN_ID="$$-$(date +%s)"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
LOOP_SANDBOX="${LOOP_SANDBOX:-0}"
LOOP_IMAGE="${LOOP_IMAGE:-engineering-loop:local}"

# Resolved by pre-flight from inside a container, and empty when the sandbox is off.
LOOP_SOCK_GID=""

# Declared ONCE so the host path and the sandboxed path cannot drift. A verb denied in one and not
# the other would be denied only in whichever mode nobody was using.
LOOP_DENIALS=(
  "Bash(gh pr merge *)" "Bash(gh api *)" "Bash(gh repo delete *)"
  "Bash(git push --force*)" "Bash(git push -f *)" "Bash(git push --delete *)"
  "Bash(ssh *)" "Bash(scp *)"
  "Bash(docker volume rm *)" "Bash(docker volume prune *)"
  "Bash(kubectl *)" "Bash(helm *)"
)
# The host adds its own -- a migration runner, a deploy target -- through LOOP_DENIALS_EXTRA in
# loop.env: patterns in the same `Bash(...)` form, separated by semicolons.
while IFS= read -r __d; do [ -z "$__d" ] || LOOP_DENIALS+=("$__d"); done <<EOF
$(printf '%s' "${LOOP_DENIALS_EXTRA:-}" | tr ';' '\n')
EOF
TIMEOUT_BIN=""
ESCALATED=0
PAUSED=0
CURRENT_WT=""

# The one unit this run builds, resolved by pre-flight from the ledger.
UNIT=""
BRANCH=""
UNIT_BASE=""
PHASE_COUNT=0

log()  { printf 'delivery-loop: %s\n' "$*"; }
warn() { printf 'delivery-loop: %s\n' "$*" >&2; }

# A run takes tens of minutes and ends needing a human -- a PR to review, or an escalation to read.
# Nothing on screen changes when it lands, and over SSH the terminal's own activity indicator says
# idle long before the loop is finished, so the moment that needs attention is the moment nobody is
# watching for.
#
# BEL goes to /dev/tty, not stdout: the character has to reach the TERMINAL, and stdout is routinely
# redirected to a log by whoever launched a run this long. Silence it with DELIVERY_LOOP_BELL=0.
#
# DELIVERY_LOOP_NOTIFY is the escape hatch for anything richer -- `say`, `terminal-notifier`, a curl
# to a phone. It receives the headline as $1, and a failure in it is never allowed to fail the run.
attention() {
  [ "${DELIVERY_LOOP_BELL:-1}" = "0" ] || printf '\a' > /dev/tty 2>/dev/null || true
  [ -z "${DELIVERY_LOOP_NOTIFY:-}" ] || "$DELIVERY_LOOP_NOTIFY" "$1" >/dev/null 2>&1 || true
}

escalate() {
  warn "ESCALATE ($1): $2"
  ESCALATED=1
  attention "delivery-loop: $1 escalated — $2"
}

# ---------------------------------------------------------------------------- the spec on the branch
#
# THE CHECKLISTS LIVE WHERE THE WORK LIVES. The phase ticks and the ledger tick are commits on the
# unit's branch and reach `main` only when the PR merges, so while a unit is being built the
# checkout's copy of the spec shows no progress at all. When the branch exists on origin, its copy
# is the one read; before that, the checkout's.
#
# /archive-spec MOVES the spec to .ai/specs/implemented/ when it ticks the last unit, so on a finished
# branch the spec is no longer at the path this run was given. Every read of the branch's copy tries
# the archived path second; the driver checkout's copy, which shows no progress, comes last.
archived_spec() {
  printf '%s/implemented/%s' "$(dirname "$SPEC")" "$(basename "$SPEC")"
}

spec_on_branch() {
  local out="$1"
  if [ -n "$BRANCH" ] && git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null; then
    git show "origin/$BRANCH:$SPEC" > "$out" 2>/dev/null && return 0
    git show "origin/$BRANCH:$(archived_spec)" > "$out" 2>/dev/null && return 0
  fi
  cp "$SPEC" "$out"
}

# Re-read every time it is asked: a session has just pushed a tick, and the answer is on origin.
# A checklist that does not parse is a failure, never an empty list: an empty list reads as "no
# phase is unticked", which would let a closing OK pass with nothing checked at all. The parser
# refuses a `## Progress` holding an unindented checkbox without a `**Phase N**` label -- the shape
# a session produces by writing a `- [ ] remember to …` note beneath the checklist.
refresh_phases() {
  local tmp="$PHASES.spec" rc=0
  [ -z "$BRANCH" ] || git fetch origin "$BRANCH" --quiet 2>/dev/null || true
  spec_on_branch "$tmp"
  "$LOOP_DIR/parse-ledger.sh" "$tmp" --phases > "$PHASES" 2>"$PHASES.err" || rc=$?
  rm -f "$tmp"
  if [ "$rc" != 0 ]; then
    : > "$PHASES"
    return 1
  fi
  return 0
}

next_phase() {
  awk -F'|' '$1 == " " { print $2 "|" $3; exit }' "$PHASES"
}

phase_is_ticked() {
  awk -F'|' -v p="$1" '$2 == p && $1 == "x" { found = 1 } END { exit !found }' "$PHASES"
}

unticked_phases() {
  awk -F'|' '$1 == " " { n++ } END { print n + 0 }' "$PHASES"
}

# ---------------------------------------------------------------------------- pre-flight

preflight() {
  local missing=0

  # timeout(1) is not part of macOS; it arrives with GNU coreutils and is native on the Linux runner.
  TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
  if [ -z "$TIMEOUT_BIN" ]; then
    warn "no timeout(1). Install GNU coreutils:  brew install coreutils"
    missing=1
  fi

  for bin in jq gh git; do
    command -v "$bin" >/dev/null 2>&1 || { warn "missing required binary: $bin"; missing=1; }
  done

  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { warn "missing required binary: $CLAUDE_BIN"; missing=1; }

  if ! gh auth status >/dev/null 2>&1; then
    warn "gh is not authenticated. Run: gh auth status"
    missing=1
  fi

  # A worktree costs ~2.6GB across ~17 Docker volumes. Running out of disk mid-session leaves a
  # half-built stack and a daemon nobody can address.
  local free_gb
  free_gb="$(df -g "$ROOT" 2>/dev/null | awk 'NR==2 { print $4 }')"
  if [ -n "$free_gb" ] && [ "$free_gb" -lt 10 ]; then
    warn "only ${free_gb}GB free; free some space before an unattended run"
    missing=1
  fi

  # A DIRTY DRIVER TREE IS SOMEONE ELSE'S WORK, AND THE RUN WOULD EAT IT.
  #
  # The loop reads the spec from this tree, copies settings out of it, and the session it starts
  # commits with `git add -A`. Uncommitted changes here drive the run and get swept into whatever the
  # session commits. Refused rather than warned, because the damage lands in another branch and is
  # found much later. A dry run says it and carries on: reading the plan is exactly what you do
  # while the tree is still being worked on.
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    warn "this tree has uncommitted changes. The run reads its spec and settings from here and the"
    warn "session commits with \`git add -A\`, so they would be driven by, and swept into, the unit."
    warn "Commit or stash them, or drive the loop from a checkout nobody else is editing."
    [ "$DRY_RUN" = 1 ] || missing=1
  fi

  # THE LOOP RUNS THE TREE IT IS INVOKED FROM, INCLUDING ITSELF.
  #
  # Run from a tree behind origin/main and three things are wrong at once: the loop is an older
  # loop, the skills a session reads are older skills, and the ledger does not show what has already
  # merged. Behind is the dangerous direction and the only one checked; ahead is how this script is
  # developed.
  local behind
  behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  if [ "$behind" != 0 ]; then
    warn "this tree is $behind commit(s) behind origin/main, so the loop, the skills and the ledger"
    warn "are all older than main. Fix it:"
    warn "  git checkout main && git pull origin main"
    [ "$DRY_RUN" = 1 ] || missing=1
  fi

  # A sandbox run that cannot authenticate fails INSIDE the container, where the only evidence is a
  # denied session and a sentinel nobody could write. Refuse here instead, where the message is the
  # reason. A --dry-run builds nothing, so there an absent image or token is worth saying and not
  # worth refusing over.
  if [ "$LOOP_SANDBOX" = "1" ]; then
    local sandbox_fatal=1
    [ "$DRY_RUN" != 1 ] || sandbox_fatal=0

    command -v docker >/dev/null 2>&1 || { warn "LOOP_SANDBOX=1 needs docker"; missing=$sandbox_fatal; }
    if ! docker image inspect "$LOOP_IMAGE" >/dev/null 2>&1; then
      # Deliberately `inspect` and not `docker images`: inspect is the call that says whether the
      # image can be RUN. A manifest list is listed by `docker images` at full size and cannot be
      # resolved here.
      warn "sandbox image $LOOP_IMAGE is absent, or present but not resolvable by tag (a manifest"
      warn "list rather than a runnable image). Either way:  .loop/sandbox/build.sh"
      missing=$sandbox_fatal
    fi
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ]; then
      warn "the container inherits no login. Set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) or"
      warn "ANTHROPIC_API_KEY -- the host keychain does not reach inside."
      missing=$sandbox_fatal
    fi
    if [ -z "${GH_TOKEN:-}" ]; then
      warn "GH_TOKEN is unset, so the unit could not push its branch or open its PR."
      warn "Use a fine-grained PAT scoped to THIS repository: contents:write + pull_requests:write."
      warn "Your host gh login is deliberately not mounted."
      missing=$sandbox_fatal
    fi

    # A session that cannot reach the daemon runs a whole phase without a single gate and reports
    # success, and the loop's own host-side gate only catches it after the money is spent.
    if docker image inspect "$LOOP_IMAGE" >/dev/null 2>&1; then
      LOOP_SOCK_GID="$(docker_sock_gid)"
      if sandbox_can_run_gates "$LOOP_SOCK_GID"; then
        log "sandbox: the session can reach the Docker daemon${LOOP_SOCK_GID:+ (socket gid $LOOP_SOCK_GID)}"
      else
        warn "the sandbox cannot reach the Docker daemon, so make lint and make test would never"
        warn "start inside the session: it would build the whole phase unverified and report success."
        warn "The socket is mounted but the container's uid cannot read it. Check that"
        warn "/var/run/docker.sock exists and that the daemon is running."
        missing=$sandbox_fatal
      fi

      if sandbox_has_buildx; then
        log "sandbox: buildx is present, so the DB-backed gates can build their stack"
      else
        warn "the sandbox image has no buildx, so any gate running docker compose up --build dies on"
        warn "\"the --mount option requires BuildKit\" -- naming neither buildx nor the compose file."
        warn "Rebuild it:  .loop/sandbox/build.sh"
        missing=$sandbox_fatal
      fi

      if sandbox_reaches_origin; then
        log "sandbox: git inside the container can reach origin"
      else
        warn "git inside the sandbox cannot reach origin, so the unit would build its work and then"
        warn "fail to push it. The container mounts no ssh keys by design; an ssh remote is rewritten"
        warn "to https using GH_TOKEN, so check that GH_TOKEN is a valid repo-scoped PAT with"
        warn "contents:write, and that origin is a GitHub remote."
        missing=$sandbox_fatal
      fi
    fi
  fi

  [ "$missing" = 0 ] || return 1

  if [ ! -f "$SPEC" ]; then
    warn "no such spec: $SPEC"
    return 1
  fi

  mkdir -p "$STATE_DIR" "$WORKTREES"

  # ONE UNIT, READ FROM THE LEDGER. Parsed ONCE, here, and the run fails if it does not parse:
  # `done < <(parse-ledger …)` cannot see the parser's exit status, so a malformed ledger would
  # iterate zero times and the run would end "built nothing", exit 0 -- silence read as "there was
  # nothing to do", the worst outcome an unattended tool can produce.
  #
  # Ticked units are history: a spec delivered over several passes keeps their lines. What this run
  # builds is the ONE unticked unit. Two or more is a deployment-seam decision a human took, and
  # those are built by hand, one unit at a time -- the loop refuses rather than picks.
  if ! "$LOOP_DIR/parse-ledger.sh" "$SPEC" > "$LEDGER"; then
    warn "the ledger in $SPEC does not parse; refusing to run"
    return 1
  fi
  local owed
  owed="$(awk -F'|' '$1 == " " { n++ } END { print n + 0 }' "$LEDGER")"
  case "$owed" in
    0)
      log "every unit in $SPEC is ticked; nothing is owed"
      ;;
    1)
      UNIT="$(awk -F'|' '$1 == " " { print $2; exit }' "$LEDGER")"
      BRANCH="$(awk -F'|' '$1 == " " { print $3; exit }' "$LEDGER")"
      ;;
    *)
      warn "the ledger in $SPEC has $owed unticked units; this loop builds exactly one."
      warn "A spec with several units is built by hand, one /new-feature + /implement-spec per unit."
      return 1
      ;;
  esac

  # THE PHASES ARE THE SESSIONS. A spec whose `## Progress` has no phase checklist gives the loop
  # nothing to hand a session and nothing to check when it exits, so it is refused here rather than
  # discovered after a session was paid for. /spec-writing writes the checklist from `## Phasing`.
  if [ -n "$BRANCH" ]; then
    local phases_src="the checkout"
    ! git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null || phases_src="origin/$BRANCH"
    log "reading the phase checklist from $phases_src"
    if ! refresh_phases; then
      if grep -qE 'names no entries|no ## Progress section' "$PHASES.err"; then
        warn "$SPEC on $phases_src has no phase checklist under ## Progress; the loop hands one phase per session."
        warn "Add one line per phase: - [ ] **Phase N** — <title>   (see /spec-writing)"
      else
        warn "the ## Progress checklist in $SPEC on $phases_src does not parse; refusing to run:"
        sed 's/^/  /' "$PHASES.err" >&2
      fi
      [ "$phases_src" = "the checkout" ] || warn "The branch's copy is the one read while origin/$BRANCH exists; merge main into it or delete it."
      return 1
    fi
    PHASE_COUNT="$(wc -l < "$PHASES" | tr -d ' ')"
    [ -n "$MAX_SESSIONS" ] || MAX_SESSIONS=$((PHASE_COUNT + 2))
  fi
  return 0
}

# ---------------------------------------------------------------------------- the lock
#
# `rm -rf` + `mkdir` is two syscalls, so two loops that both see the same stale lock both "reclaim"
# it and the second reclaimer's LIVE lock is deleted by the first. Reclaiming is therefore a single
# atomic rename: exactly one racer's `mv` succeeds, the loser gets ENOENT and retries against the
# winner's fresh lock.
#
# A PID alone does not identify the holder either -- the OS recycles them, and an unrelated process
# inheriting a dead loop's PID wedges every later run permanently. The holder must be a PID whose
# command line is this script.

lock_holder_is_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -o command= -p "$pid" 2>/dev/null | grep -q 'delivery-loop.sh'
}

acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    echo "$$" > "$LOCK/pid"
    return 0
  fi

  local pid
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"

  if lock_holder_is_alive "$pid"; then
    warn "another delivery loop is running (pid $pid). Wait for it, or kill it first."
    return 1
  fi

  if [ "$FORCE_UNLOCK" != 1 ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    warn "the lock names pid $pid, which is alive but is NOT a delivery loop -- a recycled PID."
    warn "Re-run with --force-unlock if you are sure no loop is running."
    return 1
  fi

  warn "reclaiming a stale lock (pid ${pid:-unknown})"
  if ! mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
    warn "another loop reclaimed the lock first; standing down."
    return 1
  fi
  rm -rf "$LOCK.stale.$$"

  if mkdir "$LOCK" 2>/dev/null; then
    echo "$$" > "$LOCK/pid"
    return 0
  fi

  warn "another loop took the lock while it was being reclaimed; standing down."
  return 1
}

# shellcheck disable=SC2329  # reached through `trap teardown EXIT INT TERM`
teardown() {
  local rc=$?
  rm -f "${DELIVERY_LOOP_SNAPSHOT:-}"
  if [ -n "$CURRENT_WT" ] && [ -d "$CURRENT_WT" ]; then
    warn "tearing down $CURRENT_WT"
    "$LOOP_DIR/reclaim-worktree.sh" "$CURRENT_WT" >&2 || true
    CURRENT_WT=""
  fi
  rm -f "$LEDGER" "$PHASES" "$PHASES.spec" "$PHASES.err"
  if [ -f "$LOCK/pid" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK"
  fi
  exit "$rc"
}

# ---------------------------------------------------------------------------- unit helpers

checkout_worktree() {
  local wt="$1" branch="$2"
  if git rev-parse --verify --quiet "$branch" >/dev/null; then
    git worktree add "$wt" "$branch"
  else
    git worktree add -b "$branch" "$wt" "origin/$branch"
  fi
}

# Never returns "none" on a gh failure: a transient error would otherwise fall through to the build
# path as if no PR existed.
probe_unit() {
  local branch="$1" out
  if ! out="$(gh pr list --head "$branch" --state all --json number,state,mergedAt 2>/dev/null)"; then
    echo "ERROR"
    return 0
  fi
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    echo "ERROR"
    return 0
  fi
  if [ "$(printf '%s' "$out" | jq 'length')" = "0" ]; then
    echo "NONE"
    return 0
  fi
  printf '%s' "$out" | jq -r '.[0]
    | (if .mergedAt then "MERGED" else .state end)
      + " " + (.number | tostring)'
}

# The head commit of the same PR probe_unit reported, or non-zero if it cannot be read. Kept
# separate so a gh failure stays distinguishable from a PR that genuinely has no head here.
probe_unit_head() {
  local branch="$1" out
  out="$(gh pr list --head "$branch" --state all --json headRefOid 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e -r '.[0].headRefOid // empty' 2>/dev/null
}

# A MERGED PR WHOSE BRANCH IS GONE IS HISTORY, NOT THIS RUN.
#
# A spec delivered over more than one pass can reuse a branch name, and `gh pr list --state all`
# keeps answering with the PR that already merged and was then deleted. Read literally that says
# "this run already has a PR". Whether the branch still exists on origin is what separates the two
# cases, and it is asked of origin rather than inferred.
probe_run() {
  local branch="$1" state merged_head
  state="$(probe_unit "$branch")"
  case "$state" in
    MERGED*)
      if ! git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        echo "NONE"
        return 0
      fi
      # THE BRANCH EXISTING AGAIN IS NOT THE SAME BRANCH. A run pushes its first phase within the
      # hour, and from then on the retired name resolves on origin -- so "does it exist" answers
      # yes for a name this run recreated, and the stale PR reads as a live one. What separates
      # them is whether the merged PR's head is in what the branch now holds. Reachability, not
      # `origin/main..`: these PRs squash-merge, so a merged unit's own commits are absent from
      # main too, and counting commits ahead cannot tell the two cases apart.
      # Only a POSITIVE answer downgrades. An unreadable gh, a missing object, anything
      # uncertain leaves MERGED standing, because escalating a live unit is recoverable and
      # rebuilding one is not.
      if merged_head="$(probe_unit_head "$branch")" && [ -n "$merged_head" ]; then
        git cat-file -e "$merged_head^{commit}" 2>/dev/null \
          || git fetch --quiet origin "$merged_head" 2>/dev/null || true
        if git cat-file -e "$merged_head^{commit}" 2>/dev/null \
           && ! git merge-base --is-ancestor "$merged_head" "origin/$branch" 2>/dev/null; then
          echo "NONE"
          return 0
        fi
      fi
      ;;
  esac
  printf '%s' "$state"
}

# ---------------------------------------------------------------------------- the prompts
#
# Two prompts, one per kind of session. Both carry the same header lines (`Spec:`, `Unit:`, `Base:`)
# and the same sentinel template, which is what the test stub reads back.

resolve_block() {
  cat <<'BLOCK'
BEFORE writing any code, resolve every type, field, class and file this phase names -- against the
spec AND against the tree. Constructors, value objects, enum cases, interface methods, migration
columns, the fields a fingerprint or a payload covers. A spec that contradicts itself does so in a
way only building reveals: a reviewer reads what is written, an implementer has to make every
reference resolve.

Find a contradiction and you write ESCALATE and stop. Do NOT improvise past it, do not pick the
reading that lets you continue, and do not amend the spec to match what you would rather build --
the spec is a human's gate and editing it here removes the gate. A gap found now costs one re-run;
the same gap papered over silently ships an implementation nobody agreed to.
BLOCK
}

phase_prompt() {
  local spec="$1" unit="$2" branch="$3" phase="$4" title="$5" status_file="$6"
  cat <<PROMPT
You are implementing exactly one phase of an approved spec, unattended, on a branch that already
carries the phases before it.

Spec:   $spec
Unit:   $unit - branch $branch
Phase:  $phase — $title
Base:   all diffs, gates and reviews for this unit are against $UNIT_BASE, never main.

Read the spec's "## Progress" section FIRST. Its checklist says which phases are built, and the
notes under it are what the sessions before you learned that the spec does not say. Then read this
phase's own section of the spec, and only then the rest.

$(resolve_block)

You are the implementer of this phase -- do not dispatch an implementer subagent. Follow
/implement-spec's rules for a loop-driven session: the failing test first, then the code, then
/sync-context-docs and /run-gates $UNIT_BASE with every in-scope gate green. Build nothing from any
other phase, however small it looks; the next session gets the next phase.

Then, in this order:
  1. commit, exactly one commit for the code:  feat(<scope>): $phase — $title (spec: $spec)
  2. in the spec, tick this phase's line under "## Progress" (- [x] **$phase** …) and rewrite the
     notes beneath the checklist: what you learned that the spec does not already say, and what the
     next phase must know. Commit that too.
  3. push
  4. write the sentinel.

Before exiting, write exactly one line to this file
  $status_file
That line is one of:
  CONTINUE $branch <the sha you pushed> $RUN_ID
                              this phase is built, gated, ticked and pushed; the next session
                              takes the next phase
  ESCALATE:<one-line reason>  for anything else - a failed precondition, a contradiction in the
                              spec, a gate you could not turn green, or any question you would
                              otherwise ask a human.
Never write OK: that line belongs to the closing session. Never leave the file unwritten; a
missing file is treated as an escalation.
PROMPT
}

final_prompt() {
  local spec="$1" unit="$2" branch="$3" status_file="$4"
  cat <<PROMPT
Every phase of an approved spec is built and ticked on this branch. You close the unit out,
unattended: review it, tick its ledger, and stop before the PR.

This is a headless session. The moment you end your turn the process exits, this worktree is
removed, and anything not pushed is gone. So nothing runs in the background -- run gates and
reviewers in the foreground and wait for them -- and every step below ends with a commit and a
push before the next one starts.

Spec:   $spec
Unit:   $unit - branch $branch
Base:   all diffs, gates and reviews for this unit are against $UNIT_BASE, never main.

In this order:
  1. /sync-context-docs against $UNIT_BASE; commit and push anything it changes.
  2. /code-review over  git diff \$(git merge-base "$UNIT_BASE" HEAD)...HEAD  -- the reviewers run on
     opus. Resolve every Critical and High finding in one fix wave; commit and push it. Then
     /run-gates $UNIT_BASE in the foreground until every in-scope gate is green, and one scoped
     re-review; commit and push.
     A finding you cannot resolve without a human is an ESCALATE, not a note in the PR.
  3. /archive-spec $spec -- it ticks this unit's ledger line and archives the spec. Commit and push.
  4. Do NOT open a pull request: the run opens it once it has re-run the gates itself.

The last thing you do, after the final push, is write exactly one line to this file
  $status_file
That line is one of:
  OK $branch <the sha you pushed> $RUN_ID
                              the unit is reviewed, ticked and pushed
  ESCALATE:<one-line reason>  for anything else.
Never leave it unwritten. A missing file is treated as an escalation.
PROMPT
}

# ---------------------------------------------------------------------------- build

cp_settings() {
  local wt="$1"
  mkdir -p "$wt/.claude"
  [ ! -f "$ROOT/.claude/settings.local.json" ] || cp "$ROOT/.claude/settings.local.json" "$wt/.claude/settings.local.json"
}

# One session. The worktree is continued when it exists, checked out when the branch exists on
# origin, and created from origin/main otherwise -- never rebuilt: an existing worktree or branch is
# always the work of the sessions before this one, and `git branch -D` would throw it away.
run_session() {
  local prompt="$1" json_file="$2"
  local wt="$WORKTREES/$BRANCH" rc

  if [ -d "$wt" ]; then
    CURRENT_WT="$wt"
  elif git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null; then
    checkout_worktree "$wt" "$BRANCH" || { escalate "$UNIT" "could not check out $BRANCH"; return 1; }
    CURRENT_WT="$wt"
    cp_settings "$wt"
  else
    git branch -D "$BRANCH" >/dev/null 2>&1 || true
    log "$UNIT: worktree $wt on $BRANCH from origin/main"
    if ! git worktree add -b "$BRANCH" "$wt" origin/main; then
      escalate "$UNIT" "git worktree add failed; not running claude into a directory that is not there"
      return 1
    fi
    CURRENT_WT="$wt"
    # settings.local.json is gitignored, so it is absent from every worktree the loop creates. The
    # copy gives the session the permissions the human has already proved sufficient; only the
    # dangerous verbs are denied.
    cp_settings "$wt"
  fi

  # A sandboxed session whose container cannot resolve the repository discovers it the expensive
  # way: the session starts, spends turns working out that `git` has nothing to talk to, and
  # escalates. Probing here costs one container start, and the worktree only exists from this line
  # onwards -- which is why the check cannot live in pre-flight.
  if [ "$LOOP_SANDBOX" = "1" ] && ! sandbox_sees_repo "$wt"; then
    escalate "$UNIT" "the sandbox container cannot resolve this worktree's git repository"
    warn "A linked worktree's .git names an absolute path into the main repo. Both it and"
    warn "\$ROOT/.git must be mounted, read-write -- git writes refs, objects and the index there."
    return 1
  fi

  run_claude "$wt" "$prompt" "$json_file" "$LOOP_MODEL"
  rc=$?
  [ "$rc" = 124 ] && { escalate "$UNIT" "timed out after ${UNIT_TIMEOUT}s"; return 1; }
  return 0
}

# `--permission-mode bypassPermissions` is the difference between a loop that runs and one that
# cannot write a single file. Headless `-p` has nobody to answer a prompt, so any tool not already
# allowed is DENIED SILENTLY -- including the escalation sentinel a session tries to write to say so.
#
# It does not weaken the denials below. Rules are evaluated deny, then ask, then allow, and the
# first match wins: "if a tool is denied at any level, no other level can allow it". Bypass skips
# PROMPTS, not deny rules -- so those stay blocked, and they are the guard that replaces the human
# who is not sitting there. It cannot be done from a settings file either: `bypassPermissions` is
# ignored from project and local settings, and only takes effect from user/managed settings or this
# flag.
#
# The denials are exact matches -- without a `*` the match is exact -- so a host that adds
# `Bash(make migrate)` through LOOP_DENIALS_EXTRA still lets `make migrate-diff` run: a session may
# GENERATE a migration and ship the file; applying one to a database stays a human decision.
#
# EACH VERB IS DENIED BY EVERY ROUTE TO IT, not by its most obvious name. `Bash(git push --force*)`
# does not match `git push -f`, because the match is exact up to the wildcard. The same holds for a
# deploy target beside a bare `ssh`, and `gh pr merge` beside `gh api -X PUT .../merge`.
#
# THIS LIST IS STILL A BLOCKLIST AND STILL LOSES. It cannot enumerate every way to destroy
# something, and it protects nothing outside this repository: on the host the session runs as the
# user, with their ssh keys and their gh token. The real bound is `LOOP_SANDBOX=1`, which runs the
# session in a container with the worktree mounted and no host credentials.
#
# THE WORKTREE IS MOUNTED AT ITS OWN HOST PATH, not at a tidy /repo. Every gate runs
# `docker compose`, whose bind mounts are resolved by the HOST daemon through the socket below --
# so a worktree mounted at /repo would have the daemon look for /repo on the host and find nothing.
#
# The state dir is mounted too because the sentinel deliberately lives OUTSIDE the worktree, and
# the session has to be able to write it.
#
# THE MAIN REPOSITORY'S .git IS MOUNTED, and it has to be. A linked worktree is not self-contained:
# its `.git` is a FILE reading `gitdir: <main repo>/.git/worktrees/<name>`, an absolute path into a
# directory the container could not otherwise see. It widens what the container can reach to the
# whole repository; the socket two lines below is host root, so straining at .git while mounting the
# daemon would be theatre. The sandbox bounds LATERAL reach: ~/.ssh, the host home, other
# repositories, your gh login.
#
# It runs as the invoking uid so everything it writes into the worktree is owned by the human who
# will review it, not by root.
#
# THE CONTAINER HAS NO SSH KEYS, ON PURPOSE -- SO GIT HAS TO SPEAK HTTPS. This repo's origin is an
# ssh remote, so inside the container every fetch and push would fail. The credential to use is
# already there: GH_TOKEN, deliberately a repo-scoped PAT, rewritten through git's own
# url.<base>.insteadOf and passed as environment rather than written into any config file. The ssh
# prefix is taken from the actual remote rather than assumed, because it is a per-user ssh alias
# (`git@github.com-personal:`) and not a hostname anyone could guess.
sandbox_git_env() {
  local url prefix
  url="$(git remote get-url origin 2>/dev/null || true)"
  case "$url" in
    git@*:*) prefix="${url%%:*}:" ;;
    ssh://*) prefix="ssh://${url#ssh://}"; prefix="${prefix%%/*}/" ;;
    *)       return 0 ;;
  esac
  [ -n "${GH_TOKEN:-}" ] || return 0
  printf '%s\n' \
    "GIT_CONFIG_COUNT=1" \
    "GIT_CONFIG_KEY_0=url.https://x-access-token:${GH_TOKEN}@github.com/.insteadOf" \
    "GIT_CONFIG_VALUE_0=${prefix}"
}

# The rewrite as `docker run -e` arguments, filled into SANDBOX_GIT_ENV for the callers below.
SANDBOX_GIT_ENV=()
load_sandbox_git_env() {
  local line
  SANDBOX_GIT_ENV=()
  while IFS= read -r line; do [ -z "$line" ] || SANDBOX_GIT_ENV+=(-e "$line"); done <<EOF
$(sandbox_git_env)
EOF
}

run_claude_sandboxed() {
  local wt="$1" prompt="$2" json_file="$3" model="$4" rc=0
  load_sandbox_git_env

  "$TIMEOUT_BIN" "$UNIT_TIMEOUT" docker run --rm -i \
    -u "$(id -u):$(id -g)" \
    ${LOOP_SOCK_GID:+--group-add "$LOOP_SOCK_GID"} \
    -v "$wt:$wt" \
    -v "$ROOT/.git:$ROOT/.git" \
    -v "$STATE_DIR:$STATE_DIR" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -w "$wt" \
    -e CLAUDE_CODE_OAUTH_TOKEN -e ANTHROPIC_API_KEY -e GH_TOKEN \
    ${SANDBOX_GIT_ENV[@]+"${SANDBOX_GIT_ENV[@]}"} \
    "$LOOP_IMAGE" \
      -p "$prompt" \
      --model "$model" \
      --output-format json \
      --permission-mode bypassPermissions \
      --disallowedTools "${LOOP_DENIALS[@]}" > "$json_file" 2>"$json_file.err" || rc=$?
  return "$rc"
}

# Peak context is the largest single turn's input: cache reads plus cache creation plus fresh
# input. Context grows through a session, so the last turn is normally the peak; taking the max
# rather than the last is what keeps that true across a compaction.
peak_context() {
  jq -r '([.usage.iterations[]? | (.cache_read_input_tokens//0) + (.cache_creation_input_tokens//0) + (.input_tokens//0)] | max) // 0' "$1" 2>/dev/null || echo 0
}

context_alarm() {
  local json_file="$1" label="$2" peak
  [ -s "$json_file" ] || return 0
  peak="$(peak_context "$json_file")"
  if [ "$peak" -gt "$SESSION_CONTEXT_ALARM" ] 2>/dev/null; then
    warn "$label: peak context $peak exceeds SESSION_CONTEXT_ALARM=$SESSION_CONTEXT_ALARM -- this phase is cut too large"
  fi
}

# THE SOCKET IS MOUNTED; BEING ABLE TO READ IT IS A SEPARATE QUESTION.
#
# The container runs as the host user's uid:gid so files it writes in the worktree are owned by
# them. That uid is in no group inside the container, and the socket is group-owned and mode 660 --
# so the mount succeeds, `docker` is on PATH, and every call is denied. Every gate in this repo is
# `docker compose`, so the session cannot run one and the whole phase is built unverified.
#
# The gid is read from INSIDE a container rather than off the host, because they are not the same
# number: on Docker Desktop the socket the container sees belongs to the VM's daemon, not to the
# host's `docker` group.
docker_sock_gid() {
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint stat "$LOOP_IMAGE" -c '%g' /var/run/docker.sock 2>/dev/null || true
}

# Asserts the capability, not the mount: can a container started exactly as a session is started
# actually reach the daemon? Anything less passes while `make` is still dead.
sandbox_can_run_gates() {
  local gid="$1"
  docker run --rm \
    -u "$(id -u):$(id -g)" \
    ${gid:+--group-add "$gid"} \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint docker \
    "$LOOP_IMAGE" version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# Can git inside the container REACH origin? The gitdir probe below answers a local question and
# passes even when every fetch and push would fail: no ssh keys, an ssh remote, nothing to
# authenticate with.
sandbox_reaches_origin() {
  load_sandbox_git_env
  docker run --rm \
    -u "$(id -u):$(id -g)" \
    -e GH_TOKEN ${SANDBOX_GIT_ENV[@]+"${SANDBOX_GIT_ENV[@]}"} \
    --entrypoint git \
    "$LOOP_IMAGE" ls-remote "$(git remote get-url origin)" HEAD >/dev/null 2>&1
}

# `docker compose up --build` is how every DB-backed gate starts, this repo's Dockerfiles use
# `RUN --mount=type=cache`, and that needs BuildKit. Without the buildx plugin the gate dies on
# "the --mount option requires BuildKit", naming neither buildx nor the compose file.
sandbox_has_buildx() {
  docker run --rm --entrypoint docker "$LOOP_IMAGE" buildx version >/dev/null 2>&1
}

# One container start, before a session is paid for. It asserts the thing the mounts exist to
# provide rather than the mounts themselves: whether `git` inside can name this worktree's gitdir.
sandbox_sees_repo() {
  local wt="$1"
  docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$wt:$wt" \
    -v "$ROOT/.git:$ROOT/.git" \
    -w "$wt" \
    --entrypoint git \
    "$LOOP_IMAGE" rev-parse --git-dir >/dev/null 2>&1
}

run_claude() {
  local wt="$1" prompt="$2" json_file="$3" model="$4" rc=0

  if [ "$LOOP_SANDBOX" = "1" ]; then
    run_claude_sandboxed "$@" || rc=$?
    return "$rc"
  fi

  ( cd "$wt" && "$TIMEOUT_BIN" "$UNIT_TIMEOUT" "$CLAUDE_BIN" -p "$prompt" \
      --model "$model" \
      --output-format json \
      --permission-mode bypassPermissions \
      --disallowedTools "${LOOP_DENIALS[@]}" ) > "$json_file" 2>"$json_file.err" || rc=$?
  return "$rc"
}

# A SESSION REFUSED FOR THE USAGE LIMIT IS A PAUSE, NOT A FAILURE. The unit is neither finished nor
# wrong; the account is out of quota until it resets. The JSON shape is the same is_error as any
# other hard failure; what separates it is the HTTP status the CLI reports beside it, `api_error_status`
# 429. The text is only a fallback for a CLI that does not report the status -- and the CLI's own
# wording is "session limit", not "usage limit", so a text match alone once let a refusal escalate.
hit_usage_limit() {
  local json_file="$1"
  [ -s "$json_file" ] || return 1
  [ "$(jq -r '.is_error // false' "$json_file" 2>/dev/null)" = "true" ] || return 1
  [ "$(jq -r '.api_error_status // 0' "$json_file" 2>/dev/null)" = "429" ] && return 0
  jq -r '.result // ""' "$json_file" 2>/dev/null \
    | grep -qiE 'usage limit|session limit|rate limit|quota|too many requests|429'
}

# ---------------------------------------------------------------------------- verify and prove

# A Claude session that stops to ask a question exits 0, reporting subtype "success" and
# is_error false, having done nothing. A hard API error reports is_error true alongside subtype
# "success". So subtype is never consulted: is_error, permission_denials and the sentinel are.
#
# Returns 0 for a verified OK, 2 for a verified CONTINUE, 1 for an escalation.
verify_session() {
  local expected_phase="$1" json_file="$2"
  local status_file="$STATE_DIR/$BRANCH.status"
  local sentinel tip handover=0

  # Read before anything else: a session refused for the usage limit wrote no sentinel and did no
  # work, and neither of those is a finding about the unit.
  if hit_usage_limit "$json_file"; then
    return 3
  fi

  # Denials are read BEFORE the sentinel. A session denied `Write` cannot write the sentinel either,
  # so checking the sentinel first reports "no sentinel written" for what is actually a permission
  # problem -- the failure hides its own cause.
  if [ -s "$json_file" ] \
     && [ "$(jq -r '(.permission_denials // []) | length' "$json_file" 2>/dev/null)" != "0" ]; then
    escalate "$UNIT" "permission denials: $(jq -c '[.permission_denials[].tool_name] | unique' "$json_file" 2>/dev/null)"
    return 1
  fi

  if [ ! -f "$status_file" ]; then
    escalate "$UNIT" "no sentinel was written; treating as an escalation"
    return 1
  fi
  sentinel="$(cat "$status_file")"

  case "$sentinel" in
    ESCALATE:*) escalate "$UNIT" "${sentinel#ESCALATE:}"; return 1 ;;
  esac

  # A handover is checked exactly as hard as a completion -- same tip, same run. The difference is
  # only what the loop does next, and a CONTINUE that did not really push is the one way this could
  # silently lose a session's work.
  case "$sentinel" in
    CONTINUE\ *) handover=1; sentinel="OK ${sentinel#CONTINUE }" ;;
  esac

  if [ -s "$json_file" ]; then
    if [ "$(jq -r '.is_error // false' "$json_file" 2>/dev/null)" = "true" ]; then
      escalate "$UNIT" "claude reported is_error: $(jq -r '.result // "no result text"' "$json_file" | head -c 200)"
      return 1
    fi
  fi

  tip="$(git ls-remote --heads origin "$BRANCH" 2>/dev/null | awk '{ print $1 }')"
  if [ -z "$tip" ]; then
    escalate "$UNIT" "the sentinel claims success but $BRANCH is not on origin"
    return 1
  fi
  if [ "$sentinel" != "OK $BRANCH $tip $RUN_ID" ]; then
    escalate "$UNIT" "sentinel does not match this run and the origin tip: '$sentinel'"
    return 1
  fi

  if [ "$(git rev-list --count "origin/main..origin/$BRANCH" 2>/dev/null || echo 0)" = "0" ]; then
    escalate "$UNIT" "$BRANCH carries no commits over main"
    return 1
  fi

  # THE TICK IS THE PROOF OF PROGRESS. A phase session says CONTINUE; whether it finished its phase
  # is read from the checklist it was told to tick, on origin, not from its say-so. A closing
  # session says OK; every phase must be ticked there. The wrong sentinel for the session's kind is
  # an escalation too: a phase session writing OK is claiming a review that never ran.
  if ! refresh_phases; then
    escalate "$UNIT" "the ## Progress checklist on origin/$BRANCH no longer parses: $(head -1 "$PHASES.err")"
    return 1
  fi
  if [ "$handover" = 1 ]; then
    [ -n "$expected_phase" ] || { escalate "$UNIT" "the closing session handed over instead of finishing"; return 1; }
    if ! phase_is_ticked "$expected_phase"; then
      escalate "$UNIT" "the session handed over without ticking $expected_phase in ## Progress"
      return 1
    fi
    return 2
  fi
  [ -z "$expected_phase" ] || { escalate "$UNIT" "a phase session wrote OK; only the closing session may"; return 1; }
  if [ "$(unticked_phases)" != 0 ]; then
    escalate "$UNIT" "OK was written with $(unticked_phases) phase(s) still unticked in ## Progress"
    return 1
  fi
  return 0
}

# The sentinel is the model reporting on its own work -- a claim, not a proof, and the model that
# wrote the code is the worst judge of whether it works. This is the first machine check the loop
# does not have to trust. A failure is an escalation, never a retry of the session: the unit is
# finished and wrong, which is a different thing from unfinished.
#
# A RED GATE IS RUN TWICE BEFORE IT IS BELIEVED, AND ONLY THIS GATE. Re-running costs one gate run and
# no tokens; escalating on a false red costs the remainder of an unattended night and leaves a
# built, pushed, correct unit looking broken. `composer install` dying mid-extraction under
# concurrent Docker load is the shape this covers: a toolchain that fell over is not "finished and
# wrong", it is "we do not know yet". Deliberately NOT applied to the session: a session is expensive
# and non-deterministic, and re-running one that escalated repeats a decision it already made.
prove_unit() {
  local attempt
  for attempt in 1 2; do
    log "$UNIT: proving with LOOP_GATES on the host (attempt $attempt)"
    if run_gates "$WORKTREES/$BRANCH"; then
      return 0
    fi
    [ "$attempt" = 1 ] || break
    warn "$UNIT: the gate came back red; re-running it once before believing it, since a toolchain"
    warn "that fell over and a unit that is wrong look identical from an exit code."
  done
  escalate "$UNIT" "LOOP_GATES failed twice in the finished unit"
  return 1
}

# The host's gates, one after another, from the unit's worktree. A semicolon separates commands;
# the first red one stops the run.
run_gates() {
  local wt="$1" gate
  while IFS= read -r gate; do
    [ -n "$gate" ] || continue
    log "$UNIT: gate: $gate"
    ( cd "$wt" && bash -c "$gate" ) || return 1
  done <<EOF
$(printf '%s' "$LOOP_GATES" | tr ';' '\n')
EOF
  return 0
}

# ---------------------------------------------------------------------------- record

ledger_of_branch() {
  local tmp
  tmp="$(mktemp)"
  git show "$BRANCH:$SPEC" > "$tmp" 2>/dev/null \
    || git show "origin/$BRANCH:$SPEC" > "$tmp" 2>/dev/null \
    || git show "$BRANCH:$(archived_spec)" > "$tmp" 2>/dev/null \
    || git show "origin/$BRANCH:$(archived_spec)" > "$tmp" 2>/dev/null \
    || cp "$SPEC" "$tmp"
  printf '%s' "$tmp"
}

# TICKED IS NOT RECORDED. The tick is written in TWO passes: /archive-spec writes `- [x] … — est ~N`
# from inside the closing session, before the PR exists and before anything can be measured; this
# loop's `record` stage then rewrites that same line with the realised measurements and the PR
# number. So the question is whether the line carries its MEASUREMENT, not whether it carries an x
# -- and whether the telemetry exists, because /archive-spec can write the whole measured line
# itself, and a check that asks only about the ledger would then skip `record_telemetry`.
# The ledger tick is the last thing the closing session writes, after the review and its fixes, so a
# ticked line on the branch means the unit is closed. A run that finds it does not review the unit
# again; what can still be owed is the PR and the record, which follow.
unit_is_ticked() {
  local tmp rc=1
  tmp="$(ledger_of_branch)"
  grep -qE "^- \\[[xX]\\][[:space:]]+\\*\\*$UNIT\\*\\*" "$tmp" && rc=0
  rm -f "$tmp"
  return $rc
}

unit_is_recorded() {
  local tmp rc=1 slug telem
  tmp="$(ledger_of_branch)"
  grep -qE "^- \\[[xX]\\][[:space:]]+\\*\\*$UNIT\\*\\*.* → [0-9]+ lines" "$tmp" && rc=0
  rm -f "$tmp"
  [ "$rc" = 0 ] || return 1

  slug="$(basename "$SPEC" .md)"
  telem=".ai/telemetry/$slug/$(printf '%s' "$UNIT" | tr ' /' '--').md"
  git cat-file -e "$BRANCH:$telem" 2>/dev/null && return 0
  git cat-file -e "origin/$BRANCH:$telem" 2>/dev/null && return 0
  return 1
}

# WHAT A UNIT COST TO BUILD, ONE ROW PER SESSION.
#
# Context is what a session costs, and it is driven by how much of the tree the session had to
# READ, not by how much it wrote. Recording each session's peak beside the alarm is what shows
# which phase was cut too large, and it is the only evidence the phase-per-session shape is doing
# what it is for.
record_telemetry() {
  local pr_number="$1" wt="$2" measured="$3"
  local dir slug file json rows=""

  slug="$(basename "$SPEC" .md)"
  dir="$wt/.ai/telemetry/$slug"
  mkdir -p "$dir"
  file="$dir/$(printf '%s' "$UNIT" | tr ' /' '--').md"

  # Named so a lexical glob is chronological across runs: a unit resumed by a later invocation
  # keeps its earlier sessions in order.
  for json in "$STATE_DIR/$BRANCH".s*.json; do
    [ -s "$json" ] || continue
    # A session refused before it started (the usage limit) built nothing and has no row.
    [ "$(jq -r '.is_error // false' "$json" 2>/dev/null)" != "true" ] || continue
    rows="$rows$(jq -r --arg alarm "$SESSION_CONTEXT_ALARM" '
      ([.usage.iterations[]? | (.cache_read_input_tokens//0) + (.cache_creation_input_tokens//0) + (.input_tokens//0)] | max) as $peak |
      "| " + (.loop_phase // "closing") + " | " + (.num_turns|tostring) + " | $" + ((.total_cost_usd*100|round/100)|tostring)
        + " | " + (($peak // 0)|tostring) + (if ($peak // 0) > ($alarm|tonumber) then " ⚠" else "" end)
        + " | " + ((.duration_ms/60000|round)|tostring) + " min | " + ((.modelUsage | keys | join(", ")) // "?") + " |"
    ' "$json" 2>/dev/null || true)
"
  done

  # The backticks are markdown, not command substitution.
  # shellcheck disable=SC2016
  {
    printf '# %s — `%s`\n\n' "$UNIT" "$BRANCH"
    printf '| | |\n|---|---|\n'
    printf '| PR | %s |\n' "${pr_number:+#$pr_number}"
    printf '| size | %s |\n' "$measured"
    printf '| context alarm | %s |\n\n' "$SESSION_CONTEXT_ALARM"
    printf '| session | turns | cost | peak context | wall clock | model |\n|---|---|---|---|---|---|\n'
    printf '%s' "$rows"
  } > "$file"
}

# Idempotent. A restarted run must leave the ledger ticked exactly once.
record_unit() {
  local pr_number="$1"
  local wt="$WORKTREES/$BRANCH"
  local measured line spec_in_wt

  if unit_is_recorded; then
    log "$UNIT is already recorded"
    return 0
  fi

  # The loop can crash between /open-pr and this commit, which leaves an open PR whose unit is
  # unticked and whose worktree has been reclaimed. The tick belongs on the unit's own branch, so
  # take the branch out again rather than committing a claim about this unit onto main.
  if [ ! -d "$wt" ]; then
    log "$UNIT: no worktree; checking $BRANCH out to record the tick"
    checkout_worktree "$wt" "$BRANCH" >/dev/null 2>&1 \
      || { escalate "$UNIT" "ledger is unticked and $BRANCH cannot be checked out; tick it by hand"; return 1; }
    CURRENT_WT="$wt"
  fi

  measured="$( cd "$wt" && "$LOOP_DIR/unit-size.sh" origin/main || true )"
  line="$measured"
  [ -n "$pr_number" ] && line="$line (#$pr_number)"

  record_telemetry "$pr_number" "$wt" "$measured"

  spec_in_wt="$SPEC"
  [ -f "$wt/$SPEC" ] || spec_in_wt="$(archived_spec)"

  log "$UNIT: recording -> $line"
  ( cd "$wt" \
    && awk -v unit="$UNIT" -v m="$line" '
        $0 ~ "^- \\[[ xX]\\] \\*\\*" unit "\\*\\*" {
          sub(/^- \[[ xX]\]/, "- [x]")
          # REPLACE, never "append when absent": /archive-spec writes a measured line from inside
          # the session. The figures here are the authoritative ones, taken after the last commit.
          # (No apostrophes in this block: awk is inside a single-quoted shell string.)
          sub(/ → .*$/, "")
          $0 = $0 " → " m
          print; next
        }
        { print }
      ' "$spec_in_wt" > "$spec_in_wt.tmp" \
    && mv "$spec_in_wt.tmp" "$spec_in_wt" \
    && git add "$spec_in_wt" .ai/telemetry \
    && git commit -q -m "docs(ai): tick $UNIT with its measured size" \
    && git push -q origin "$BRANCH" ) || { escalate "$UNIT" "could not record the tick"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------- plan

print_plan() {
  local done_flag phase title
  if [ -z "$BRANCH" ]; then
    log "nothing to build"
    return 0
  fi
  log "unit:   $UNIT on $BRANCH, from origin/main, one PR at the end"
  log "state:  $(probe_run "$BRANCH")"
  log "phases: $PHASE_COUNT, one session each, then a closing session (MAX_SESSIONS=$MAX_SESSIONS)"
  while IFS='|' read -r done_flag phase title; do
    [ -n "$phase" ] || continue
    printf '  [%s] %s — %s\n' "$done_flag" "$phase" "$title"
  done < "$PHASES"
}

# ---------------------------------------------------------------------------- main

if ! preflight; then
  warn "pre-flight failed"
  exit 3
fi

if [ "$DRY_RUN" = 1 ]; then
  log "spec: $SPEC"
  # LOOP_SANDBOX is reported because it is the ONE setting whose whole point is that the outcome
  # looks identical either way: a host run and a container run produce the same PR. Left out of this
  # line, a run believed to be sandboxed and a run that silently was not are indistinguishable.
  log "bounds: MAX_SESSIONS=${MAX_SESSIONS:-—} UNIT_TIMEOUT=${UNIT_TIMEOUT}s SESSION_CONTEXT_ALARM=$SESSION_CONTEXT_ALARM"
  log "gates:  $LOOP_GATES"
  log "models: build sessions on $LOOP_MODEL, the PR session on $PR_MODEL"
  if [ "$LOOP_SANDBOX" = "1" ]; then
    log "sandbox: ON — sessions run in $LOOP_IMAGE"
  else
    log "sandbox: OFF — sessions run on this host, with your ssh keys and gh login"
  fi
  log "timeout: $TIMEOUT_BIN"
  print_plan
  rm -f "$LEDGER" "$PHASES" "$PHASES.err"
  exit 0
fi

if [ -z "$BRANCH" ]; then
  rm -f "$LEDGER" "$PHASES" "$PHASES.err"
  exit 0
fi

if ! acquire_lock; then
  exit 3
fi
trap teardown EXIT INT TERM

git fetch origin --quiet || warn "git fetch failed; working from the refs already here"

STATE="$(probe_run "$BRANCH")"
PR_NUMBER=""
case "$STATE" in
  ERROR)
    escalate "$UNIT" "gh could not be read; aborting rather than risking a rebuild of a live unit"
    exit 4
    ;;
  CLOSED*)
    escalate "$UNIT" "its PR is closed and unmerged -- a human rejected this unit"
    exit 4
    ;;
  MERGED*)
    escalate "$UNIT" "its PR is merged but the ledger is unticked; tick it by hand"
    exit 4
    ;;
  OPEN*)
    PR_NUMBER="$(echo "$STATE" | awk '{ print $2 }')"
    log "$UNIT already has PR #$PR_NUMBER; new commits are pushed to it"
    ;;
esac

# THE BASE IS WHERE THIS UNIT STARTED: the commit the branch was cut from, which is its merge-base
# with main once the branch exists and main itself before that. A resumed run must not take the
# branch TIP, or every gate and the closing review would see only the phases built in this
# invocation. Pinned to a sha so a moving main does not move it under the sessions.
UNIT_BASE="$(git merge-base origin/main "origin/$BRANCH" 2>/dev/null \
  || git rev-parse origin/main)"

# ONE PHASE PER SESSION, AS MANY SESSIONS AS THERE ARE PHASES, THEN ONE TO CLOSE. A session that
# hands over is not finished and not stuck; the answer is a fresh process on the same worktree and
# branch, given the next unticked phase. The gates run in every session, on that session's phase;
# `prove` runs once more on the host when the closing session says OK, because the loop does not
# take a session's word for a green gate either.
SESSIONS=0
UNIT_OK=0
while :; do
  if [ "$SESSIONS" -ge "$MAX_SESSIONS" ]; then
    escalate "$UNIT" "still not finished after $SESSIONS sessions (MAX_SESSIONS=$MAX_SESSIONS); it is not converging"
    break
  fi
  SESSIONS=$((SESSIONS + 1))
  STATUS_FILE="$STATE_DIR/$BRANCH.status"
  # Epoch, then pid, then the session number: a lexical glob is chronological across runs, and two
  # runs started within the same second cannot overwrite each other's sessions.
  JSON_FILE="$STATE_DIR/$BRANCH.s${RUN_ID#*-}-$$-$(printf '%02d' "$SESSIONS").json"
  rm -f "$STATUS_FILE"

  NEXT="$(next_phase)"
  if [ -n "$NEXT" ]; then
    PHASE="${NEXT%%|*}"
    TITLE="${NEXT#*|}"
    log "$UNIT: session $SESSIONS builds $PHASE — $TITLE"
    run_session "$(phase_prompt "$SPEC" "$UNIT" "$BRANCH" "$PHASE" "$TITLE" "$STATUS_FILE")" "$JSON_FILE" || break
  elif unit_is_ticked; then
    SESSIONS=$((SESSIONS - 1))
    log "$UNIT: every phase is ticked and the ledger is ticked on $BRANCH; the unit is closed"
    if [ ! -d "$WORKTREES/$BRANCH" ]; then
      checkout_worktree "$WORKTREES/$BRANCH" "$BRANCH" >/dev/null 2>&1 \
        || { escalate "$UNIT" "could not check out $BRANCH to prove and record it"; break; }
      cp_settings "$WORKTREES/$BRANCH"
    fi
    CURRENT_WT="$WORKTREES/$BRANCH"
    UNIT_OK=1
    break
  else
    PHASE=""
    log "$UNIT: session $SESSIONS closes the unit: review, ledger tick, archive"
    run_session "$(final_prompt "$SPEC" "$UNIT" "$BRANCH" "$STATUS_FILE")" "$JSON_FILE" || break
  fi
  # The phase is stamped into the session's JSON so the telemetry can name it, and the latest
  # session is also kept under the plain branch name, which is where a human reads the last
  # session's whole result after an escalation.
  if [ -s "$JSON_FILE" ] && jq --arg p "${PHASE:-closing}" '. + {loop_phase: $p}' "$JSON_FILE" > "$JSON_FILE.tmp" 2>/dev/null; then
    mv "$JSON_FILE.tmp" "$JSON_FILE"
  fi
  rm -f "$JSON_FILE.tmp"
  cp "$JSON_FILE" "$STATE_DIR/$BRANCH.json" 2>/dev/null || true
  context_alarm "$JSON_FILE" "${PHASE:-closing session}"

  VERDICT=0
  verify_session "$PHASE" "$JSON_FILE" || VERDICT=$?
  case "$VERDICT" in
    0) UNIT_OK=1; break ;;
    2) log "$UNIT: $PHASE is ticked and pushed; continuing in a fresh session" ;;
    3) PAUSED=1; break ;;
    *) break ;;
  esac
done

if [ "$UNIT_OK" = 1 ] && prove_unit; then
  # One PR for the whole unit, opened once and attested on origin. The loop refuses to take a
  # session's word that something happened everywhere else; its own last step is no exception: a
  # session can exit 0 having opened nothing.
  if [ "$(probe_run "$BRANCH")" = "NONE" ]; then
    log "opening the PR for $UNIT on $BRANCH"
    run_claude "$WORKTREES/$BRANCH" \
      "Run /open-pr with --base main. This branch carries the whole delivery unit $UNIT of $SPEC, one
commit per phase. Title it: <type>(<scope>): <the feature>. Do not list the phases in the title." \
      "$STATE_DIR/$BRANCH.pr.json" "$PR_MODEL" || escalate "$UNIT" "/open-pr failed"
    if [ "$(probe_run "$BRANCH")" = "NONE" ]; then
      escalate "$UNIT" "the PR was reported open but origin has none for this branch; open it by hand"
    else
      PR_NUMBER="$(probe_run "$BRANCH" | awk '{ print $2 }')"
    fi
  fi

  # Recorded AFTER the PR so the tick carries its number; the tick is what a later run reads to
  # know the unit is delivered, so it is written even when the PR step escalated.
  record_unit "$PR_NUMBER" || true
fi

if [ -n "$CURRENT_WT" ] && [ -d "$CURRENT_WT" ]; then
  "$LOOP_DIR/reclaim-worktree.sh" "$CURRENT_WT" || warn "reclaim of $CURRENT_WT did not complete"
  CURRENT_WT=""
fi

log "$SESSIONS session(s) this run"
if [ "$PAUSED" = 1 ]; then
  log "paused: the usage limit is reached. Re-run the same command once it resets; the loop continues"
  log "from the first unticked phase on $BRANCH."
  attention "delivery-loop: paused on the usage limit — re-run to continue $UNIT"
  exit 5
fi
[ "$ESCALATED" = 0 ] || exit 4
[ "$UNIT_OK" = 0 ] || attention "delivery-loop: $UNIT built, PR #${PR_NUMBER:-?} open and waiting for review"
exit 0
