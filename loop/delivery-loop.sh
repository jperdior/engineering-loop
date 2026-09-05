#!/usr/bin/env bash
#
# Build a spec's delivery unit unattended: one fresh `claude -p` per spec phase, on one branch, then
# one closing session for the review, then one PR. The loop never merges; a human merges the PR.
#
# Usage:
#   delivery-loop.sh <spec-file> [--dry-run] [--force-unlock]
#
#   --dry-run       run pre-flight and print the unit, its branch, its phases and the bounds.
#                   Creates nothing. Run this first against any real spec.
#   --force-unlock  take a lock this script refuses to reclaim on its own.
#
# Settings are environment variables, read from .loop/loop.env (see loop.env.dist). The shell wins
# over the file. The main ones:
#
#   LOOP_GATES="make lint;make test"  the host's gates, run from the repo root in this order.
#   LOOP_MODEL=opus                   the model of every build session; the PR session runs on sonnet.
#   MAX_SESSIONS=<phases>+2           sessions per invocation before the unit is declared non-converging.
#   UNIT_TIMEOUT=7200                 seconds per session, enforced by timeout(1).
#   SESSION_CONTEXT_ALARM=150000      a session whose peak context exceeds this is reported, not stopped.
#
# There is no budget: the unit is built until it is done. A session refused for the account's usage
# limit pauses the run (exit 5) instead of escalating; re-running the same command continues from
# the first unticked phase.
#
# Exit: 0 the unit is done or nothing is owed, 2 usage, 3 pre-flight or lock failure, 4 an escalation,
#       5 paused on the usage limit.

set -euo pipefail

# Run from a snapshot of this script. Bash reads a script incrementally, so editing this file while
# a run is in flight would have it execute a torn file. The copy is removed by teardown.
if [ -z "${DELIVERY_LOOP_SNAPSHOT:-}" ]; then
  __snap="$(mktemp -t delivery-loop.XXXXXX)"
  cat "$0" > "$__snap"
  chmod +x "$__snap"
  # The snapshot lives in a temp dir, so the real location is carried across the exec.
  DELIVERY_LOOP_ORIGIN="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
  export DELIVERY_LOOP_ORIGIN
  export DELIVERY_LOOP_SNAPSHOT="$__snap"
  exec "$__snap" "$@"
fi
# Covers every exit before `trap teardown EXIT` replaces it.
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

# The engine lives in <repo>/.loop/. The root is resolved through git so the engine can be vendored
# anywhere a host puts it.
LOOP_DIR="$(cd "$(dirname "${DELIVERY_LOOP_ORIGIN:-$0}")" && pwd -P)"
cd "$(git -C "$LOOP_DIR" rev-parse --show-toplevel)"
ROOT="$(pwd -P)"

# The ledger tick is written from inside the unit's worktree, so the spec path must be root-relative
# to land on the unit's branch rather than in the main checkout.
case "$SPEC" in
  "$ROOT"/*) SPEC="${SPEC#"$ROOT"/}" ;;
  /*) echo "delivery-loop: the spec must live inside $ROOT" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------- configuration file
#
# .loop/loop.env holds the settings and the two sandbox credentials. A value already exported in
# the shell is never overwritten, so `LOOP_MODEL=sonnet .loop/delivery-loop.sh …` still works.
load_env_file() {
  local f="$LOOP_DIR/loop.env" line key val
  [ -f "$f" ] || return 0

  # The file holds tokens. GNU stat first: BSD's -c fails while GNU's -f answers something else.
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

# A session is one phase, and that is what bounds its context. A session cannot observe its own
# token count, so a budget in the prompt is not obeyed; a phase is observable from outside. The loop
# reads the `## Progress` checklist on the branch, hands the next unticked phase to a fresh process,
# and checks the tick when that process exits. SESSION_CONTEXT_ALARM is a reading on the telemetry,
# not a limit.
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

# Resolved by pre-flight from inside a container; empty when the sandbox is off.
LOOP_SOCK_GID=""

# Declared once so the host path and the sandboxed path cannot drift. Each verb is denied by every
# route to it: `git push --force*` does not match `git push -f`, and `gh pr merge` has a twin in
# `gh api -X PUT .../merge`.
LOOP_DENIALS=(
  "Bash(gh pr merge *)" "Bash(gh api *)" "Bash(gh repo delete *)"
  "Bash(git push --force*)" "Bash(git push -f *)" "Bash(git push --delete *)"
  "Bash(ssh *)" "Bash(scp *)"
  "Bash(docker volume rm *)" "Bash(docker volume prune *)"
  "Bash(kubectl *)" "Bash(helm *)"
)
# The host adds its own through LOOP_DENIALS_EXTRA: `Bash(...)` patterns separated by semicolons.
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

# A run ends needing a human, long after anyone stopped watching. The bell goes to /dev/tty because
# stdout is usually a log file. DELIVERY_LOOP_NOTIFY receives the headline as $1 and may never fail
# the run.
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
# The phase ticks and the ledger tick are commits on the unit's branch and reach main only when the
# PR merges. While the branch exists on origin, its copy of the spec is the one read.
#
# /archive-spec moves the spec to .ai/specs/implemented/ when it ticks the last unit, so on a
# finished branch the spec is no longer at the path this run was given. Every read of the branch's
# copy tries the archived path second; the driver checkout's copy comes last.
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

# Re-read every time: a session has just pushed a tick. A checklist that does not parse is a
# failure, never an empty list, because an empty list reads as "nothing unticked" and would let a
# closing OK pass with nothing checked.
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

  # timeout(1) is not part of macOS; it arrives with GNU coreutils.
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

  # Running out of disk mid-session leaves a half-built stack nobody can address. POSIX `df -Pk`
  # answers on both GNU and BSD; `df -g` does not exist on Linux.
  local free_gb
  free_gb="$(df -Pk "$ROOT" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1048576 }')"
  if [ -n "$free_gb" ] && [ "$free_gb" -lt 10 ]; then
    warn "only ${free_gb}GB free; free some space before an unattended run"
    missing=1
  fi

  # A dirty driver tree is someone else's work. The loop reads the spec and settings from here and
  # the session commits with `git add -A`, so uncommitted changes would be swept into the unit and
  # found much later on another branch. A dry run only warns: reading the plan is what you do while
  # the tree is still being edited.
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    warn "this tree has uncommitted changes. The run reads its spec and settings from here and the"
    warn "session commits with \`git add -A\`, so they would be driven by, and swept into, the unit."
    warn "Commit or stash them, or drive the loop from a checkout nobody else is editing."
    [ "$DRY_RUN" = 1 ] || missing=1
  fi

  # A tree behind origin/main runs an older loop, older skills and an older ledger. Behind is the
  # dangerous direction; ahead is how this script is developed.
  local behind
  behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  if [ "$behind" != 0 ]; then
    warn "this tree is $behind commit(s) behind origin/main, so the loop, the skills and the ledger"
    warn "are all older than main. Fix it:"
    warn "  git checkout main && git pull origin main"
    [ "$DRY_RUN" = 1 ] || missing=1
  fi

  # A sandbox run that cannot authenticate or reach the daemon fails inside the container, where
  # the only evidence is a denied session. Refuse here, where the message is the reason. A dry run
  # builds nothing, so there these are warnings.
  if [ "$LOOP_SANDBOX" = "1" ]; then
    local sandbox_fatal=1
    [ "$DRY_RUN" != 1 ] || sandbox_fatal=0

    command -v docker >/dev/null 2>&1 || { warn "LOOP_SANDBOX=1 needs docker"; missing=$sandbox_fatal; }
    if ! docker image inspect "$LOOP_IMAGE" >/dev/null 2>&1; then
      # `inspect`, not `docker images`: inspect says whether the tag can be run. A manifest list is
      # listed by `docker images` and cannot be resolved here.
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
    # success; the loop's host-side gate only catches it after the money is spent.
    if docker image inspect "$LOOP_IMAGE" >/dev/null 2>&1; then
      LOOP_SOCK_GID="$(docker_sock_gid)"
      if sandbox_can_run_gates "$LOOP_SOCK_GID"; then
        log "sandbox: the session can reach the Docker daemon${LOOP_SOCK_GID:+ (socket gid $LOOP_SOCK_GID)}"
      else
        warn "the sandbox cannot reach the Docker daemon, so any gate that uses docker would never"
        warn "start inside the session: it would build the whole phase unverified and report success."
        warn "The socket is mounted but the container's uid cannot read it. Check that"
        warn "/var/run/docker.sock exists and that the daemon is running."
        missing=$sandbox_fatal
      fi

      if sandbox_has_buildx; then
        log "sandbox: buildx is present, so gates that build images can run"
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

  # One unit, read from the ledger, parsed once. The run fails if the ledger does not parse: a
  # malformed ledger read as an empty list would end "built nothing", exit 0, which is the worst
  # outcome an unattended tool can produce. Ticked units are history; this run builds the one
  # unticked unit. Two or more is a deployment-seam decision a human took, built by hand.
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

  # A spec without a phase checklist gives the loop nothing to hand a session, so it is refused
  # here rather than discovered after a session was paid for.
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
# Reclaiming a stale lock is a single atomic rename, so two loops that both see it cannot both
# "reclaim" it and delete each other's fresh lock. A PID alone does not identify the holder either:
# the OS recycles them, so the holder must be a PID whose command line is this script.

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

# The head commit of the PR probe_unit reported, or non-zero if it cannot be read. Kept separate so
# a gh failure stays distinguishable from a PR with no head.
probe_unit_head() {
  local branch="$1" out
  out="$(gh pr list --head "$branch" --state all --json headRefOid 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e -r '.[0].headRefOid // empty' 2>/dev/null
}

# A merged PR whose branch is gone is history, not this run. A spec delivered over several passes
# can reuse a branch name, and `gh pr list --state all` keeps answering with the merged PR. Once
# this run has pushed, the name resolves on origin again, so existence is not enough either: the
# merged PR's head must be reachable from what the branch now holds. Only a positive answer
# downgrades MERGED to NONE; anything uncertain leaves MERGED standing, because escalating a live
# unit is recoverable and rebuilding one is not. Reachability rather than `origin/main..` because
# squash-merges leave a merged unit's commits absent from main too.
probe_run() {
  local branch="$1" state merged_head
  state="$(probe_unit "$branch")"
  case "$state" in
    MERGED*)
      if ! git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        echo "NONE"
        return 0
      fi
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
# and the same sentinel template, which is also what the test stub reads back.

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

# settings.local.json is gitignored, so it is absent from every worktree the loop creates. The copy
# gives the session the permissions the human has already proved sufficient.
cp_settings() {
  local wt="$1"
  mkdir -p "$wt/.claude"
  [ ! -f "$ROOT/.claude/settings.local.json" ] || cp "$ROOT/.claude/settings.local.json" "$wt/.claude/settings.local.json"
}

# One session. The worktree is continued when it exists, checked out when the branch exists on
# origin, and created from origin/main otherwise. A branch on origin is always the work of earlier
# sessions and is never rebuilt. A local branch that never reached origin is a session that failed
# before its first push; it is dropped and the phase starts over.
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
    cp_settings "$wt"
  fi

  # A sandboxed session whose container cannot resolve the repository would spend turns discovering
  # it. One container start here is cheaper; the worktree only exists from this line onwards, which
  # is why the check is not in pre-flight.
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

# Why `--permission-mode bypassPermissions`: headless `-p` has nobody to answer a prompt, so any tool
# not already allowed is denied silently, including the sentinel the session would write to say so.
# Bypass skips prompts, not deny rules: rules are evaluated deny, then ask, then allow, and a denied
# tool stays denied. The flag cannot come from a project settings file; only user/managed settings
# or the command line may set it.
#
# The denials are exact up to a `*`, so a host that adds `Bash(make migrate)` still lets
# `make migrate-diff` run. The list is a blocklist and cannot enumerate every way to destroy
# something; on the host the session runs as the user with their ssh keys and gh login. The real
# bound is LOOP_SANDBOX=1.
#
# About the sandbox mounts:
#   - The worktree is mounted at its own host path, not at /repo, because a gate that runs
#     `docker compose` has its bind mounts resolved by the host daemon through the socket.
#   - The main repository's .git is mounted because a linked worktree's `.git` is a file pointing
#     into it by absolute path. The socket already grants host root, so this widens nothing that
#     matters; what the sandbox bounds is lateral reach: ~/.ssh, the host home, other repositories,
#     the gh login.
#   - The state dir is mounted because the sentinel lives outside the worktree.
#   - It runs as the invoking uid so the worktree stays owned by the human who reviews it.
#
# The container has no ssh keys, so git must speak https. An ssh remote is rewritten to
# https://x-access-token:$GH_TOKEN@github.com/ through git's own url.<base>.insteadOf, passed as
# environment rather than written to any config file. The ssh prefix is taken from the actual remote
# because it may be a per-user ssh alias rather than a hostname.
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

# The rewrite as `docker run -e` arguments.
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

# Peak context is the largest single turn's input: cache reads plus cache creation plus fresh input.
# The max rather than the last turn keeps this true across a compaction.
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

# The socket is mounted; being able to read it is a separate question. The container runs as the
# host user's uid, which is in no group inside the container, and the socket is group-owned 660.
# The gid is read from inside a container because on Docker Desktop it is the VM daemon's number,
# not the host's `docker` group.
docker_sock_gid() {
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint stat "$LOOP_IMAGE" -c '%g' /var/run/docker.sock 2>/dev/null || true
}

# Asserts the capability, not the mount: can a container started as a session is started reach the
# daemon?
sandbox_can_run_gates() {
  local gid="$1"
  docker run --rm \
    -u "$(id -u):$(id -g)" \
    ${gid:+--group-add "$gid"} \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint docker \
    "$LOOP_IMAGE" version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# Can git inside the container reach origin? The gitdir probe answers a local question and passes
# even when every fetch and push would fail.
sandbox_reaches_origin() {
  load_sandbox_git_env
  docker run --rm \
    -u "$(id -u):$(id -g)" \
    -e GH_TOKEN ${SANDBOX_GIT_ENV[@]+"${SANDBOX_GIT_ENV[@]}"} \
    --entrypoint git \
    "$LOOP_IMAGE" ls-remote "$(git remote get-url origin)" HEAD >/dev/null 2>&1
}

# A gate that runs `docker compose up --build` on a Dockerfile using `RUN --mount=type=cache` needs
# BuildKit, which is the buildx plugin. Without it the gate dies on "the --mount option requires
# BuildKit", naming neither buildx nor the compose file.
sandbox_has_buildx() {
  docker run --rm --entrypoint docker "$LOOP_IMAGE" buildx version >/dev/null 2>&1
}

# Whether `git` inside the container can name this worktree's gitdir. One container start, before a
# session is paid for.
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

# A session refused for the usage limit is a pause, not a failure. The JSON is the same is_error as
# any hard failure; what separates it is `api_error_status` 429. The text match is a fallback for a
# CLI that does not report the status, and the CLI's own wording is "session limit".
hit_usage_limit() {
  local json_file="$1"
  [ -s "$json_file" ] || return 1
  [ "$(jq -r '.is_error // false' "$json_file" 2>/dev/null)" = "true" ] || return 1
  [ "$(jq -r '.api_error_status // 0' "$json_file" 2>/dev/null)" = "429" ] && return 0
  jq -r '.result // ""' "$json_file" 2>/dev/null \
    | grep -qiE 'usage limit|session limit|rate limit|quota|too many requests|429'
}

# ---------------------------------------------------------------------------- verify and prove

# A session that stops to ask a question exits 0 with subtype "success" and is_error false, having
# done nothing. A hard API error reports is_error true alongside subtype "success". So subtype is
# never consulted: is_error, permission_denials and the sentinel are.
#
# Returns 0 for a verified OK, 2 for a verified CONTINUE, 3 for a usage-limit pause, 1 otherwise.
verify_session() {
  local expected_phase="$1" json_file="$2"
  local status_file="$STATE_DIR/$BRANCH.status"
  local sentinel tip handover=0

  # A session refused for the usage limit wrote no sentinel and did no work; neither is a finding
  # about the unit.
  if hit_usage_limit "$json_file"; then
    return 3
  fi

  # Denials before the sentinel: a session denied `Write` cannot write the sentinel either, and
  # "no sentinel" would hide the real cause.
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

  # A handover is checked as hard as a completion: same tip, same run. A CONTINUE that did not push
  # is the one way the loop could silently lose a session's work.
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

  # The tick is the proof of progress. A phase session says CONTINUE; whether it finished is read
  # from the checklist on origin, not from its say-so. A closing session says OK; every phase must
  # be ticked. The wrong sentinel for the session's kind is an escalation too.
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

# The sentinel is the model reporting on its own work. This is the first check the loop does not
# have to trust. A failure is an escalation, never a retry of the session: the unit is finished and
# wrong, which differs from unfinished.
#
# A red gate is run twice before it is believed, and only the gate. Re-running costs one gate run
# and no tokens; escalating on a toolchain that fell over costs the rest of an unattended night. A
# session is never re-run: it is expensive, non-deterministic, and re-running one that escalated
# repeats a decision it already made.
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

# The host's gates, in order, from the unit's worktree. The first red one stops the run.
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

# The ledger tick is the last thing the closing work writes, after the review and its fixes, so a
# ticked line on the branch means the unit is closed. A run that finds it does not review the unit
# again; what can still be owed is the PR and the record, which follow.
unit_is_ticked() {
  local tmp rc=1
  tmp="$(ledger_of_branch)"
  grep -qE "^- \\[[xX]\\][[:space:]]+\\*\\*$UNIT\\*\\*" "$tmp" && rc=0
  rm -f "$tmp"
  return $rc
}

# Ticked is not recorded. /archive-spec ticks the line from inside the closing session, before the
# PR exists; `record_unit` then rewrites that line with the measurements and the PR number. So the
# question is whether the line carries its measurement, and whether the telemetry file exists.
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

# What a unit cost to build, one row per session. Context is what a session costs, and recording
# each session's peak beside the alarm is what shows which phase was cut too large.
record_telemetry() {
  local pr_number="$1" wt="$2" measured="$3"
  local dir slug file json rows=""

  slug="$(basename "$SPEC" .md)"
  dir="$wt/.ai/telemetry/$slug"
  mkdir -p "$dir"
  file="$dir/$(printf '%s' "$UNIT" | tr ' /' '--').md"

  # Session files are named so a lexical glob is chronological across runs.
  for json in "$STATE_DIR/$BRANCH".s*.json; do
    [ -s "$json" ] || continue
    # A session refused before it started built nothing and has no row.
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

# Idempotent: a restarted run leaves the ledger ticked exactly once.
record_unit() {
  local pr_number="$1"
  local wt="$WORKTREES/$BRANCH"
  local measured line spec_in_wt

  if unit_is_recorded; then
    log "$UNIT is already recorded"
    return 0
  fi

  # The loop can crash between /open-pr and this commit, leaving an open PR whose unit is unticked
  # and whose worktree is gone. The tick belongs on the unit's branch, so check it out again.
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
          # Replace, never append: /archive-spec may already have written a measured line, and the
          # figures here are taken after the last commit. (No apostrophes: awk is single-quoted.)
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
  # LOOP_SANDBOX is reported because a host run and a container run produce the same PR; left out,
  # a run believed sandboxed and one that was not would be indistinguishable.
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

# The base is where this unit started: the merge-base with main once the branch exists, main itself
# before that. A resumed run must not take the branch tip, or every gate and the closing review would
# see only the phases built in this invocation. Pinned to a sha so a moving main does not move it.
UNIT_BASE="$(git merge-base origin/main "origin/$BRANCH" 2>/dev/null \
  || git rev-parse origin/main)"

# One phase per session, as many sessions as there are phases, then one to close. The gates run in
# every session on that session's phase; `prove_unit` runs them once more on the host when the
# closing session says OK.
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
  # The phase is stamped into the session's JSON so the telemetry can name it. The latest session is
  # also kept under the plain branch name, which is where a human reads it after an escalation.
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
  # One PR for the whole unit, opened once and attested on origin: a session can exit 0 having
  # opened nothing.
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

  # Recorded after the PR so the tick carries its number. The tick is what a later run reads to
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
