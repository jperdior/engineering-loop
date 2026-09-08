#!/usr/bin/env bash
#
# Build a spec's delivery unit unattended: one fresh `claude -p` per spec phase, on one branch, then
# three closing sessions (context docs, code review, archive), then one PR. The loop never merges; a
# human merges the PR.
#
# Usage:
#   delivery-loop.sh <spec-file> [--dry-run] [--force-unlock]
#
#   --dry-run       run pre-flight and print the unit, its branch, its phases, the bounds and what
#                   a re-run would resume. Creates nothing. Run this first against any real spec.
#   --force-unlock  take THIS UNIT's lock when this script refuses to reclaim it on its own. It
#                   cannot take one the unit's own session is still behind.
#
# The host contract -- the gates, the per-worktree cleanup, the generated paths, the extra denials
# -- is read from the SPEC's `## Gates` section, on the branch, like the phases. /spec-writing
# derives it from the repository's own docs every time a spec is written, and the human approves it
# with the rest of the spec. Nothing about the host is configured in a file for this loop's sake.
#
# Settings are environment variables, read from the user's `~/.config/engineering-loop/loop.env` (see
# loop.env.dist): the sandbox tokens and per-developer knobs. The shell wins over the file. The main
# ones:
#
#   LOOP_MODEL=opus                   the model of every build session; the PR session runs on sonnet.
#   MAX_SESSIONS=<phases>+4           sessions per invocation before the unit is declared non-converging.
#   UNIT_TIMEOUT=7200                 seconds per session, enforced by timeout(1).
#   SESSION_CONTEXT_ALARM=<tokens>    a session whose context exceeds this is reported, not stopped. Unset,
#                                     the alarm is half of the session's model context window.
#
# There is no budget: the unit is built until it is done. A session refused for the account's usage
# limit pauses the run (exit 5) instead of escalating; re-running the same command continues the
# refused session, in the worktree it left behind.
#
# A STOP KEEPS ITS WORKTREE. Only the done path reclaims -- after the unit is proved, its PR is open
# and its tick is recorded. Every other exit leaves the worktree, because the interrupted session's
# work is only in there. Drop one by hand with the plugin's `reclaim-worktree.sh <path>`; the run
# names both on its way out. The RECORD of the session in flight is kept by fewer exits than the worktree
# is: a session that wrote its own `ESCALATE:` had its say, so its record goes and the re-run builds
# that phase fresh in the tree it left.
#
# IT BUILDS WHERE IT IS DRIVEN FROM. Run it from a linked worktree that is already on the unit's
# branch and the unit is built in THAT tree: no second worktree, no checkout, and no reclaim on any
# path -- the driver was there before the run and outlives it. Run it from a main checkout and it
# creates `.claude/worktrees/<branch>`. While a run is in flight the worktree is the loop's: a
# session commits with `git add -A` unless it was told it inherited a predecessor's tree, so an edit
# made in it mid-run is swept into the unit. The loop's own state -- the lock, the unit directories,
# the worktrees it creates, the telemetry -- lives under the user's state directory, keyed by the
# repository; nothing of it is written into the repository.
#
# ONE LOOP PER UNIT, SEVERAL PER REPOSITORY. The lock is `lock/<branch>/`, so two specs build side
# by side from two shells; everything else a run writes is keyed by branch, bar `.git/config`, which
# `with_config_lock` serialises. What two runs genuinely share is outside this repository -- the
# account's usage limit, the host's memory, BuildKit's cache -- and none of it is something a lock
# can arbitrate.
#
# Exit: 0 the unit is done or nothing is owed (the worktree is reclaimed), 2 usage, 3 pre-flight or
#       lock failure, 4 an escalation, 5 paused on the usage limit. 4 and 5 keep the worktree.

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

# The engine is a Claude Code plugin: these scripts live under the plugin's directory, not in any
# repository. The repository is the one the loop is run FROM, so nothing of the engine is committed
# into a host -- the host writes its specs, and only its specs.
LOOP_DIR="$(cd "$(dirname "${DELIVERY_LOOP_ORIGIN:-$0}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$LOOP_DIR/.." && pwd -P)"
if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "delivery-loop: run this from inside the repository to build; the current directory is not in one" >&2
  exit 2
fi
cd "$ROOT"
ROOT="$(pwd -P)"

# The main checkout identifies the repository, whichever of its worktrees the loop is driven from:
# the lock and the unit directories are keyed by it, so two drivers of one unit meet the same lock.
# `git worktree list` names the main worktree on its first line whatever the git directory is called;
# stripping `/.git` off the common dir fails silently under --separate-git-dir or a symlinked .git.
MAIN_ROOT="$ROOT"
_main_wt="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
[ -z "$_main_wt" ] || [ ! -d "$_main_wt" ] || MAIN_ROOT="$(cd "$_main_wt" && pwd -P)"
unset _main_wt

# The ledger tick is written from inside the unit's worktree, so the spec path must be root-relative
# to land on the unit's branch rather than in the main checkout.
case "$SPEC" in
  "$ROOT"/*) SPEC="${SPEC#"$ROOT"/}" ;;
  /*) echo "delivery-loop: the spec must live inside $ROOT" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------- configuration file
#
# The settings file is the user's, outside every repository: `~/.config/engineering-loop/loop.env`
# (LOOP_ENV overrides the path). It holds the two sandbox credentials and per-developer knobs, and
# nothing about any host. A value already exported in the shell is never overwritten, so
# `LOOP_MODEL=sonnet delivery-loop.sh …` still works.
#
# `secret` marks a file that holds tokens and should not be readable beyond its owner.
load_env_file() {
  local f="$1" secret="${2:-}" line key val
  [ -f "$f" ] || return 0

  if [ -n "$secret" ]; then
    # GNU stat first: BSD's -c fails while GNU's -f answers something else.
    case "$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)" in
      ?[1-7]?|??[1-7]) printf 'delivery-loop: %s is readable beyond you; chmod 600 it\n' "$f" >&2 ;;
    esac
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    [ -z "${!key:-}" ] || continue
    export "$key=$val"
    [ "$key" != LOOP_GATES ] || LOOP_GATES_FROM="$f"
  done < "$f"
}

# Where the gates came from is reported by --dry-run: a run whose gates were a shell override and a
# run reading the spec produce the same PR, and only this line tells them apart. The override exists
# for the harness and for a one-off; the spec is the source.
LOOP_GATES_FROM=""
[ -z "${LOOP_GATES:-}" ] || LOOP_GATES_FROM="the shell"

LOOP_ENV="${LOOP_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/engineering-loop/loop.env}"
load_env_file "$LOOP_ENV" secret

# A session is one phase, and that is what bounds its context. A session cannot observe its own
# token count, so a budget in the prompt is not obeyed; a phase is observable from outside. The loop
# reads the `## Progress` checklist on the branch, hands the next unticked phase to a fresh process,
# and checks the tick when that process exits. SESSION_CONTEXT_ALARM is a reading on the telemetry,
# not a limit.
LOOP_GATES="${LOOP_GATES:-}"
LOOP_CLEAN_WORKTREE="${LOOP_CLEAN_WORKTREE:-}"
LOOP_SIZE_EXCLUDES="${LOOP_SIZE_EXCLUDES:-}"
LOOP_DENIALS_EXTRA="${LOOP_DENIALS_EXTRA:-}"
LOOP_MODEL="${LOOP_MODEL:-opus}"
PR_MODEL="sonnet"
SESSION_CONTEXT_ALARM="${SESSION_CONTEXT_ALARM:-}"
MAX_SESSIONS="${MAX_SESSIONS:-}"

UNIT_TIMEOUT="${UNIT_TIMEOUT:-7200}"

# The loop's state lives under the user's state directory, keyed by the repository: its main
# checkout's basename plus a checksum of that path, so two clones of one project on one machine do
# not share a lock or a worktree. Nothing of it is written into the repository. LOOP_STATE_DIR names
# the per-repository directory outright, which is what the harness uses.
STATE_DIR="${LOOP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/engineering-loop/$(basename "$MAIN_ROOT")-$(printf '%s' "$MAIN_ROOT" | cksum | cut -d' ' -f1)}"
mkdir -p "$STATE_DIR"
STATE_DIR="$(cd "$STATE_DIR" && pwd -P)"
LOCK="$STATE_DIR/lock"
# This run's own lock, `$LOCK/<branch>`, set by acquire_lock. Empty until then, and `teardown` reads
# it rather than recomputing it from BRANCH: an empty BRANCH would spell `$LOCK//pid`, which is the
# pre-change repository-wide lock file and belongs to nobody here.
LOCK_DIR=""
LEDGER="$STATE_DIR/ledger.$$"
PHASES="$STATE_DIR/phases.$$"
# A worktree the loop creates lives beside its state, outside the repository; a worktree the loop is
# driven from is wherever the human put it.
WORKTREES="$STATE_DIR/worktrees"
RUN_ID="$$-$(date +%s)"

# Where this unit is built. Normally a worktree of its own under `.claude/worktrees/<branch>`; when
# the loop is driven from a linked worktree ALREADY on the unit's branch, that worktree itself --
# nothing is added, nothing is checked out, and nothing is ever reclaimed, because the driver
# outlives the run. Both are resolved by pre-flight, once the ledger names the branch.
IN_PLACE=0
UNIT_WT=""

# The repository's common `.git`, which is what a container has to see. A linked worktree's `.git` is
# a FILE reading `gitdir: <main repo>/.git/worktrees/<name>`, so a container given only the file has
# no repository at all. Resolved by pre-flight; from a main checkout it is ROOT/.git.
GIT_COMMON="$MAIN_ROOT/.git"

# Everything this unit's session may read or write outside the worktree: the sentinel, the session
# record, and the transcript the sandbox keeps. Resolved by pre-flight; empty until then.
UNIT_DIR=""

# The id the current session is launched with, minted on the host and read by both launchers.
SESSION_ID=""

# The conversation the next session CONTINUES instead of starting. Set by `resume_decision` from the
# record an interrupted session left, read by both launchers, and cleared after that one session --
# a resume continues one interrupted session; it is never a mode the rest of the run inherits.
RESUME_ID=""

# `resume_decision --report` sets this, and it is what makes the decision inert: every branch of it
# that would drop a record, escalate or set RESUME_ID prints its reason instead. --dry-run creates
# and destroys nothing, and a dry run inspecting a paused unit must not destroy the resume it is
# inspecting.
RESUME_REPORT=0

# How many session containers this run has started. The container ordinal is its own and not the
# session number, because the PR-opening launch shares the last closing session's.
CONTAINER_N=0

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
# No default. Running on the host, with the user's ssh keys, gh login and Claude account, is a
# decision the user records once in loop.env; pre-flight refuses an unset switch rather than
# choosing the less safe mode by omission.
LOOP_SANDBOX="${LOOP_SANDBOX:-}"

# The container has no plugins of its own, so a sandboxed session is handed this plugin through
# `--plugin-dir`. It needs no other: every skill carries its own steps for what it would otherwise
# borrow, and the host's skills live in the repository the container mounts. On the host the session
# inherits the user's own installs.
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
# The host adds its own through the spec's `_Denials:_` line (or LOOP_DENIALS_EXTRA in the shell):
# `Bash(...)` patterns separated by semicolons. Appended once the spec has been read.
add_extra_denials() {
  local d
  while IFS= read -r d; do [ -z "$d" ] || LOOP_DENIALS+=("$d"); done <<EOF
$(printf '%s' "$LOOP_DENIALS_EXTRA" | tr ';' '\n')
EOF
}
TIMEOUT_BIN=""
ESCALATED=0
PAUSED=0
CURRENT_WT=""

# The one unit this run builds, resolved by pre-flight from the ledger.
UNIT=""
BRANCH=""
UNIT_BASE=""
PHASE_COUNT=0

# Once every phase is ticked, the unit is closed by these steps, in this order, each in its own
# session: the context docs, the whole-branch code review with its fix wave, the ledger tick and
# archive. Only the archive step leaves proof on the branch (the ticked ledger line), so a run that
# resumes with all phases ticked and the ledger unticked runs the three steps again. The docs sync
# and the review are idempotent, and a repeat costs one crash, not a marker the spec grammar lacks.
CLOSING_STEPS="docs review archive"
CLOSING_DONE=""

next_closing_step() {
  local s
  for s in $CLOSING_STEPS; do
    case " $CLOSING_DONE " in *" $s "*) ;; *) printf '%s' "$s"; return 0 ;; esac
  done
}

log()  { printf 'delivery-loop: %s\n' "$*"; }
warn() { printf 'delivery-loop: %s\n' "$*" >&2; }

# A run ends needing a human, long after anyone stopped watching. The bell goes to /dev/tty because
# stdout is usually a log file. DELIVERY_LOOP_NOTIFY receives the headline as $1 and may never fail
# the run.
attention() {
  # stderr is silenced before /dev/tty is opened: a detached run has no tty, and the shell reports
  # the failed open on the stderr it had at that point.
  [ "${DELIVERY_LOOP_BELL:-1}" = "0" ] || printf '\a' 2>/dev/null > /dev/tty || true
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

exclude_locally() {
  local common_dir
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$common_dir" ] || return 0
  mkdir -p "$common_dir/info"
  grep -qxF -- "$1" "$common_dir/info/exclude" 2>/dev/null || printf '%s\n' "$1" >> "$common_dir/info/exclude"
}

# The loop builds where it is driven from. A linked worktree already on the unit's branch IS the
# unit: the spec was written in it, the branch is checked out in it, and a second worktree of the
# same branch would only split the work across two trees git will not let both hold. So in place the
# loop adds nothing, checks out nothing, and reclaims nothing, because the tree it was invoked from
# outlives the run. Both halves are required: a main checkout has `--git-dir` and `--git-common-dir`
# naming the same directory, and a worktree on some OTHER branch is not this unit's.
resolve_unit_worktree() {
  local gitdir common

  gitdir="$(cd "$(git rev-parse --git-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
  common="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd -P || true)"
  [ -z "$common" ] || GIT_COMMON="$common"

  if [ -n "$BRANCH" ] && [ -n "$gitdir" ] && [ "$gitdir" != "$common" ] \
     && [ "$(git branch --show-current 2>/dev/null || true)" = "$BRANCH" ]; then
    IN_PLACE=1
    UNIT_WT="$ROOT"
    log "building in place: this worktree is already on $BRANCH, so the unit is built here"
  else
    IN_PLACE=0
    UNIT_WT="$WORKTREES/$BRANCH"
  fi
}

preflight() {
  local missing=0

  # The unit is resolved first, because the checks below depend on where it will be built: whether
  # this tree is the unit's own worktree decides which upstream "behind" is measured against and
  # what a stop would offer to reclaim. Reading a ledger creates nothing, so it is safe this early.
  if [ ! -f "$SPEC" ]; then
    warn "no such spec: $SPEC"
    return 1
  fi

  # The one thing the loop writes into a repository that is not the human's own work: a line in the
  # LOCAL, uncommitted exclude file, so the worktrees /new-feature creates under .claude/worktrees/
  # do not show as untracked in the main checkout and trip the dirty-tree refusal.
  exclude_locally ".claude/worktrees/"

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

  # The unit owns a directory, and it is the only state its session touches: the sentinel and the
  # transcript live here rather than beside every other unit's, so two units building at once share
  # nothing. 700 because a transcript names every file the session read.
  #
  # A `/` in the branch name is refused: `units/<branch>` is one path segment, and so is the worktree
  # directory a host's gates may key state on. Refused here rather than discovered as state written
  # somewhere nothing else looks.
  if [ -n "$BRANCH" ]; then
    case "$BRANCH" in
      */*)
        warn "the ledger names branch '$BRANCH', and a branch name may not contain '/'."
        warn "The loop's per-unit state directory and the unit's worktree directory are each one"
        warn "path segment. Rename the branch in the ledger (see /new-feature) and re-run."
        return 1
        ;;
    esac
    UNIT_DIR="$STATE_DIR/units/$BRANCH"
    mkdir -p "$UNIT_DIR/claude-config"
    chmod 700 "$UNIT_DIR"
  fi

  resolve_unit_worktree

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
  elif ! gh api "repos/$(origin_nwo)" --silent >/dev/null 2>&1; then
    # An authenticated token that cannot see this repository fails every PR read later as a 404 the
    # loop would have to read as "no PR". A fine-grained PAT scoped to another repository does this.
    warn "the GitHub token cannot read $(origin_nwo): the GH_TOKEN= line in $LOOP_ENV names a token without access to this repository. Widen it, or run $LOOP_DIR/setup-loop.sh in a terminal and paste one that has it."
    missing=1
  fi

  # Running out of disk mid-session leaves a half-built stack nobody can address. POSIX `df -Pk`
  # answers on both GNU and BSD; `df -g` does not exist on Linux.
  local free_gb kept
  free_gb="$(df -Pk "$ROOT" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1048576 }')"
  if [ -n "$free_gb" ] && [ "$free_gb" -lt 10 ]; then
    warn "only ${free_gb}GB free; free some space before an unattended run"
    kept="$(kept_worktrees)"
    if [ -n "$kept" ]; then
      warn "these worktrees are kept for a paused or escalated unit. Each one is a resume you would"
      warn "be giving up:"
      printf '%s' "$kept" >&2
    fi
    missing=1
  fi

  # A dirty driver tree is someone else's work. The loop reads the spec and settings from here and
  # the session commits with `git add -A`, so uncommitted changes would be swept into the unit and
  # found much later on another branch. A dry run only warns: reading the plan is what you do while
  # the tree is still being edited.
  #
  # In place, a session record makes the dirt the loop's own. The driver tree IS the unit's tree, a
  # session commits once at the end of its phase, and an interrupted one therefore leaves everything
  # it built uncommitted right here -- the exact state a re-run exists to continue. The record is the
  # proof: it is written before a launch and survives only an outcome the loop never verified. A
  # dirty tree with no record is still someone's work and is still refused.
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    if [ "$IN_PLACE" = 1 ] && [ -f "$UNIT_DIR/session" ]; then
      log "this tree has uncommitted changes, and $(record_field phase) was in flight here when the"
      log "last run stopped. They are that session's, and the run continues them."
    else
      warn "this tree has uncommitted changes. The run reads its spec and settings from here and the"
      warn "session commits with \`git add -A\`, so they would be driven by, and swept into, the unit."
      warn "Commit or stash them, or drive the loop from a checkout nobody else is editing."
      [ "$DRY_RUN" = 1 ] || missing=1
    fi
  fi

  # A tree behind origin/main runs an older loop, older skills and an older ledger. Behind is the
  # dangerous direction; ahead is how this script is developed.
  #
  # In place the upstream is the branch's own. A feature branch is behind main the moment main
  # moves, and that is a rebase question for the PR rather than a stale driver. What is still worth
  # refusing is a driver behind the branch's own upstream: work another run already pushed that this
  # tree has not got.
  local behind upstream
  upstream=origin/main
  [ "$IN_PLACE" = 0 ] || upstream="origin/$BRANCH"
  behind="$(git rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)"
  if [ "$behind" != 0 ]; then
    if [ "$IN_PLACE" = 1 ]; then
      warn "this worktree is $behind commit(s) behind $upstream, so a session would build on top of"
      warn "work that is already pushed. Fix it:"
      warn "  git pull --ff-only origin $BRANCH"
    else
      warn "this tree is $behind commit(s) behind origin/main, so the loop, the skills and the ledger"
      warn "are all older than main. Fix it:"
      warn "  git checkout main && git pull origin main"
    fi
    [ "$DRY_RUN" = 1 ] || missing=1
  fi

  # The host-or-container choice has to have been made, by the user, before anything runs -- a dry
  # run included, since the dry run is how /ship shows the plan and the plan names the mode.
  case "$LOOP_SANDBOX" in
    0|1) ;;
    '')
      warn "LOOP_SANDBOX is not set in $LOOP_ENV, so the loop does not know where to run sessions."
      warn "Choose once:"
      warn "  in a container with its own two tokens (recommended):   $LOOP_DIR/setup-loop.sh"
      warn "  on this host, as you, with your ssh keys, gh login and"
      warn "  the Claude account this shell is logged into:          $LOOP_DIR/setup-loop.sh --host"
      missing=1
      ;;
    *)
      warn "LOOP_SANDBOX=$LOOP_SANDBOX is neither 0 nor 1 (in $LOOP_ENV or the shell)."
      missing=1
      ;;
  esac

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
      warn "list rather than a runnable image). Either way:  $LOOP_DIR/sandbox/build.sh"
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
        warn "Rebuild it:  $LOOP_DIR/sandbox/build.sh"
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

  # Unused in place, and creating it there would leave an empty `.claude/worktrees/` in a tree
  # whose whole point is that the loop builds in it rather than beside it.
  [ "$IN_PLACE" = 1 ] || mkdir -p "$WORKTREES"

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
    # One per phase, one per closing step, one spare.
    [ -n "$MAX_SESSIONS" ] || MAX_SESSIONS=$((PHASE_COUNT + 4))
    refresh_contract || return 1
  fi
  return 0
}

# The host contract, from the spec's `## Gates` on the branch. The gates are required: a default
# here would let a spec that declares none build a whole unit against a gate nobody chose. The three
# details are optional. A shell value wins, which is what the harness and a one-off use; the source
# is reported either way. The values are exported because reclaim-worktree.sh and unit-size.sh read
# them from the environment.
join_with() {
  awk -v sep="$1" 'NF { printf "%s%s", (n++ ? sep : ""), $0 }'
}

refresh_contract() {
  local tmp="$PHASES.spec" gates
  spec_on_branch "$tmp"

  if [ -z "$LOOP_GATES" ]; then
    if ! gates="$("$LOOP_DIR/parse-ledger.sh" "$tmp" --gates 2>"$PHASES.err")"; then
      warn "$SPEC declares no gates: its ## Gates section is missing, empty or malformed."
      sed 's/^/  /' "$PHASES.err" >&2
      warn "/spec-writing writes that section from the repository's own validation commands, one"
      warn "backticked command per line; the loop will not build a unit against gates nobody chose."
      rm -f "$tmp"
      return 1
    fi
    LOOP_GATES="$(printf '%s\n' "$gates" | join_with ';')"
    LOOP_GATES_FROM="the spec"
  fi

  [ -n "$LOOP_CLEAN_WORKTREE" ] \
    || LOOP_CLEAN_WORKTREE="$("$LOOP_DIR/parse-ledger.sh" "$tmp" --host cleanup 2>/dev/null | head -1 || true)"
  [ -n "$LOOP_SIZE_EXCLUDES" ] \
    || LOOP_SIZE_EXCLUDES="$("$LOOP_DIR/parse-ledger.sh" "$tmp" --host excludes 2>/dev/null | join_with ' ' || true)"
  [ -n "$LOOP_DENIALS_EXTRA" ] \
    || LOOP_DENIALS_EXTRA="$("$LOOP_DIR/parse-ledger.sh" "$tmp" --host denials 2>/dev/null | join_with ';' || true)"
  export LOOP_CLEAN_WORKTREE LOOP_SIZE_EXCLUDES LOOP_DENIALS_EXTRA
  rm -f "$tmp"

  add_extra_denials
  return 0
}

# ---------------------------------------------------------------------------- the lock
#
# The lock is per unit: `lock/<branch>/{pid,snapshot}` under one shared parent. A repository-wide
# lock refused a second spec for no reason a run can point at -- the worktree and the unit directory
# are keyed by branch already, so two units contend over nothing this script owns.
#
# Reclaiming a stale lock is a single atomic rename, so two loops that both see it cannot both
# "reclaim" it and delete each other's fresh lock. A PID alone does not identify the holder either:
# the OS recycles them, so the holder must be a PID whose command line is the snapshot the lock
# recorded. Grepping for `delivery-loop.sh` was not that check: a running loop executes from its
# `mktemp -t delivery-loop.XXXXXX` snapshot, whose name has no `.sh`, so every live loop read as
# stale and the next run took its lock.

lock_holder_is_alive() {
  local pid="$1" snapshot="${2:-}" cmd
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  if [ -z "$snapshot" ]; then
    # No snapshot was recorded, so the holder is a loop from before this change. `delivery-loop\.`
    # covers `delivery-loop.sh` and either mktemp flavour's name.
    printf '%s\n' "$cmd" | grep -q 'delivery-loop\.'
  else
    case "$cmd" in *"$snapshot"*) true ;; *) false ;; esac
  fi
}

write_lock() {
  LOCK_DIR="$1"
  echo "$$" > "$LOCK_DIR/pid"
  printf '%s\n' "${DELIVERY_LOOP_SNAPSHOT:-}" > "$LOCK_DIR/snapshot"
}

acquire_lock() {
  # Two statements, not one `local`: bash expands every argument to `local` before the builtin runs,
  # so `local branch="$1" dir="$LOCK/$branch"` reads `branch` in the caller's scope.
  local branch="$1"
  local dir="$LOCK/$branch"

  # A session of this unit that is still running outranks --force-unlock. The lock answers "is a
  # loop running"; the unit's record answers "is a SESSION running", holding the worktree a resume
  # would reuse -- and two writers in one worktree is what keeping the worktree exists to avoid.
  if [ "$FORCE_UNLOCK" = 1 ] \
     && { lock_holder_is_alive "$(record_field host_pid)" "$(record_field snapshot)" \
          || session_container_is_running; }; then
    warn "--force-unlock refused: a session of $UNIT is still running and holds $UNIT_WT."
    warn "Kill it first (docker ps --filter name=delivery-loop-), then re-run."
    return 1
  fi

  # The pre-change lock is `lock/` itself, with a `lock/pid` inside it, and it is repository-wide.
  # Respected as such while its pid is alive, and swept when it is dead, or the first run after this
  # change would refuse forever.
  if [ -f "$LOCK/pid" ]; then
    local legacy
    legacy="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if lock_holder_is_alive "$legacy"; then
      warn "another delivery loop is running (pid $legacy). It predates the per-unit lock, so it"
      warn "holds the whole repository. Wait for it, or kill it first."
      return 1
    fi
    if [ "$FORCE_UNLOCK" != 1 ] && [ -n "$legacy" ] && kill -0 "$legacy" 2>/dev/null; then
      warn "the repository-wide lock names pid $legacy, which is alive but is NOT a delivery loop --"
      warn "a recycled PID. Re-run with --force-unlock if you are sure no loop is running."
      return 1
    fi
    warn "sweeping a repository-wide lock from before the per-unit lock (pid ${legacy:-unknown})"
    rm -f "$LOCK/pid"
  fi

  mkdir -p "$LOCK"

  if mkdir "$dir" 2>/dev/null; then
    write_lock "$dir"
    return 0
  fi

  local pid
  pid="$(cat "$dir/pid" 2>/dev/null || true)"

  if lock_holder_is_alive "$pid" "$(cat "$dir/snapshot" 2>/dev/null || true)"; then
    warn "another delivery loop is running on $branch (pid $pid). Wait for it, or kill it first."
    return 1
  fi

  if [ "$FORCE_UNLOCK" != 1 ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    warn "the lock on $branch names pid $pid, which is alive but is NOT a delivery loop -- a recycled PID."
    warn "Re-run with --force-unlock if you are sure no loop is running."
    return 1
  fi

  warn "reclaiming a stale lock on $branch (pid ${pid:-unknown})"
  if ! mv "$dir" "$dir.stale.$$" 2>/dev/null; then
    warn "another loop reclaimed the lock first; standing down."
    return 1
  fi
  rm -rf "$dir.stale.$$"

  if mkdir "$dir" 2>/dev/null; then
    write_lock "$dir"
    return 0
  fi

  warn "another loop took the lock while it was being reclaimed; standing down."
  return 1
}

# The one thing two units really share is `.git/config`, and git does not wait for it.
# `git worktree add -b <branch> <wt> origin/<ref>` sets the new branch's upstream, a write to the
# repository's config under a `config.lock` git takes optimistically: two loops adding a worktree in
# the same second race for it, and one exits 255 with "could not lock config file". The loser's
# BRANCH survives the failure, so a naive retry fails again on `a branch named 'x' already exists`.
# Serialised on a lock of its own, held for the length of one git command and never across a session.
CONFIG_LOCK="$STATE_DIR/config.lock"

with_config_lock() {
  local i=0 rc=0
  while ! mkdir "$CONFIG_LOCK" 2>/dev/null; do
    i=$((i + 1))
    # A loop killed mid-add leaves the directory behind, and no later run would ever add a worktree
    # again. Taken after 30s -- far longer than any `git worktree add` -- rather than refused.
    if [ "$i" -gt 300 ]; then
      warn "waited 30s for $CONFIG_LOCK; taking it. Remove it by hand if no other loop is running."
      rm -rf "$CONFIG_LOCK"
      mkdir "$CONFIG_LOCK" 2>/dev/null || true
      break
    fi
    sleep 0.1
  done
  "$@" || rc=$?
  rmdir "$CONFIG_LOCK" 2>/dev/null || true
  return "$rc"
}

# Teardown never reclaims the worktree. It runs on every exit, including the ones that stop with the
# phase half-built -- a usage limit, a signal, a kill -- and the work of a session that could not
# report is only in that worktree. The only reclaim is on the done path, after the unit is proved
# and recorded.
#
# shellcheck disable=SC2329  # reached through `trap teardown EXIT INT TERM HUP`
teardown() {
  local rc=$?
  rm -f "${DELIVERY_LOOP_SNAPSHOT:-}"
  rm -f "$LEDGER" "$PHASES" "$PHASES.spec" "$PHASES.err"
  kill_session_container
  # This unit's directory and nothing above it. The parent `lock/` stays: an `rmdir` of it would
  # race a sibling loop's `mkdir -p`, and it sits in the gitignored state dir and costs nothing.
  if [ -n "$LOCK_DIR" ] && [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
  exit "$rc"
}

# A container can outlive the loop that started it. `docker run` is the CLIENT: a kill -9 of the
# driver, a dropped SSH session or a memory kill of it never reaches `--rm`, and what is left is a
# container still holding the worktree, the common `.git` and GH_TOKEN -- the very worktree the next
# run picks the phase up in, so the alternative to killing it here is two writers.
#
# Guarded with `|| true` like every other teardown command: a kill of a container already gone --
# the ordinary case, since `--rm` has usually removed it -- would otherwise end the trap under
# `set -e` before the lock is released.
# shellcheck disable=SC2329  # reached through `teardown`, which the trap reaches
kill_session_container() {
  local cid
  [ -n "$UNIT_DIR" ] && [ -f "$UNIT_DIR/cid" ] || return 0
  cid="$(cat "$UNIT_DIR/cid" 2>/dev/null || true)"
  if [ -n "$cid" ] && [ -n "$(docker ps -q --no-trunc --filter "id=$cid" 2>/dev/null || true)" ]; then
    warn "killing the session container still running as $cid"
    docker kill "$cid" >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT_DIR/cid" || true
}

# The same cid, asked instead of killed. Never reads a MISSING cid as "nothing is running":
# `teardown` removes the file on every ordinary way out, so its absence is the normal case and the
# record's `host_pid` is the check that survives it.
session_container_is_running() {
  local cid
  [ -n "$UNIT_DIR" ] && [ -f "$UNIT_DIR/cid" ] || return 1
  cid="$(cat "$UNIT_DIR/cid" 2>/dev/null || true)"
  [ -n "$cid" ] || return 1
  [ -n "$(docker ps -q --no-trunc --filter "id=$cid" 2>/dev/null || true)" ]
}

# ---------------------------------------------------------------------------- the session record
#
# A session that dies leaves nothing behind saying what it was doing. The sentinel is written by the
# session, so a kill, a signal or the account's usage limit produces no sentinel at all, and the
# loop's own memory of which phase was in flight dies with the process that held it.
#
# The record is the host's note, written before the session starts and removed once the session has
# reported on itself: the phase (or `closing:<step>`), the session id, where the branch stood on
# origin at launch, and which loop launched it. It is the LOOP's file -- no prompt names it and no
# session reads it.

record_field() {
  local key="$1" file="${2:-$UNIT_DIR/session}"
  [ -f "$file" ] || return 0
  sed -n "s/^$key=//p" "$file" | head -1
}

drop_record() {
  [ -z "$UNIT_DIR" ] || rm -f "$UNIT_DIR/session"
}

# The id is minted on the host and handed to the session, because resuming one means naming a
# conversation the loop never sees the inside of. `uuidgen` is not everywhere and /proc/…/uuid is
# Linux's; neither is a pre-flight requirement, because a session with no id is a session that
# cannot be resumed -- which is what every session was until now -- and not a run worth refusing.
mint_session_id() {
  SESSION_ID="$(uuidgen 2>/dev/null | tr 'A-F' 'a-f' || true)"
  [ -n "$SESSION_ID" ] || SESSION_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
}

# `origin_tip` is read here rather than reconstructed afterwards: it is what says whether the branch
# moved under an interrupted session. It is EMPTY for a branch never pushed -- a first phase killed
# before its first push -- and that case must resume, not be told its branch is gone. An origin that
# could not be read is `unknown`, not empty: the two cannot be told apart afterwards, and the resume
# decision skips both remote guards on an empty tip.
write_session_record() {
  local phase="$1" tip listing
  if listing="$(git ls-remote --heads origin "$BRANCH" 2>/dev/null)"; then
    tip="$(printf '%s\n' "$listing" | awk '{ print $1 }')"
  else
    tip=unknown
  fi
  {
    printf 'phase=%s\n' "$phase"
    printf 'session_id=%s\n' "${SESSION_ID:-$RESUME_ID}"
    printf 'origin_tip=%s\n' "$tip"
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'host_pid=%s\n' "$$"
    printf 'snapshot=%s\n' "${DELIVERY_LOOP_SNAPSHOT:-}"
    printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$UNIT_DIR/session"
}

# A kept worktree is how disk now disappears. Only the done path reclaims, so every paused or
# escalated unit leaves a worktree behind, and the disk refusal names them: otherwise it says what
# is wrong without saying where the space went.
kept_worktrees() {
  local rec branch wt
  for rec in "$STATE_DIR"/units/*/session; do
    [ -f "$rec" ] || continue
    branch="$(basename "$(dirname "$rec")")"
    wt="$WORKTREES/$branch"
    [ -d "$wt" ] || continue
    # Never the tree this loop is running in. In place that tree is the unit, and reclaim-worktree.sh
    # would drop the driver, the branch's only checkout and the run itself.
    [ "$wt" != "$ROOT" ] || continue
    printf '  %s — %s — drop it with: %s/reclaim-worktree.sh %s\n' \
      "$wt" "$(record_field phase "$rec")" "$LOOP_DIR" "$wt"
  done
}

# What to tell a human about the unit's tree, and it is not the same sentence in both modes. Created
# for the unit, the tree is the loop's to offer up. Built in place it is the DRIVER's: the branch's
# only checkout, and while a phase is interrupted the only copy of that phase's work. Naming
# reclaim-worktree.sh for it would name the command that destroys the very thing the escalation
# exists to protect.
unit_tree_advice() {
  if [ "$IN_PLACE" = 1 ]; then
    printf 'resolve it in %s — that is your own worktree, not one the loop made' "$UNIT_WT"
  else
    printf 'reclaim %s by hand with %s/reclaim-worktree.sh %s' "$UNIT_WT" "$LOOP_DIR" "$UNIT_WT"
  fi
}

kept_worktree_note() {
  local wt="$UNIT_WT" phase
  [ "$IN_PLACE" = 0 ] || return 0
  [ -d "$wt" ] || return 0
  phase="$(record_field phase)"
  printf 'worktree kept at %s; the next run resumes %s — reclaim by hand with %s/reclaim-worktree.sh %s' \
    "$wt" "${phase:-the first unticked phase}" "$LOOP_DIR" "$wt"
}

# ---------------------------------------------------------------------------- the resume decision
#
# A re-run continues the interrupted session, it does not rebuild its phase. The session committed
# nothing -- one commit at the end of a phase is the shape -- so everything it did is uncommitted in
# a worktree that is now kept, and starting a fresh session on top of it would have that session
# discover half its own work as a stranger's. `--resume` hands the conversation back.
#
# Read in the order below, and the order is the design. Ticks are tested before tips because a
# session that pushed its tick moved the tip too. Both remote checks are gated on a non-empty
# recorded tip: an empty one is a branch that had never been pushed.
#
# It escalates rather than guesses whenever something else may be holding the same worktree, or
# whenever the branch is not where the interrupted session left it. An escalation is recoverable,
# and a resume into a tree another writer owns is not.

# A closing step's record is `closing:<step>`. Resuming it means the steps before it are done in
# this run too -- the docs sync is not repeated because the review was the one interrupted.
closing_step_of_record() {
  case "$1" in closing:*) printf '%s' "${1#closing:}" ;; esac
}

mark_closing_steps_before() {
  local target="$1" s
  CLOSING_DONE=""
  for s in $CLOSING_STEPS; do
    [ "$s" != "$target" ] || return 0
    CLOSING_DONE="$CLOSING_DONE $s"
  done
  CLOSING_DONE=""
}

resume_decision() {
  RESUME_REPORT=0
  [ "${1:-}" != --report ] || RESUME_REPORT=1

  local rec="$UNIT_DIR/session" wt="$UNIT_WT"
  local phase id tip current listing next want step

  if [ ! -f "$rec" ]; then
    [ "$RESUME_REPORT" = 0 ] || log "resume: none (no interrupted session)"
    return 0
  fi

  phase="$(record_field phase)"
  id="$(record_field session_id)"
  tip="$(record_field origin_tip)"

  # reclaim-worktree.sh does not delete the record, and it is the documented way a human refuses a
  # resume by hand.
  if [ ! -d "$wt" ]; then
    resume_fresh "a session record names ${phase:-an unnamed phase} but $wt is gone"
    return 0
  fi

  step="$(closing_step_of_record "$phase")"
  if [ -n "$phase" ] && [ -z "$step" ] && phase_is_ticked "$phase"; then
    resume_fresh "$phase is ticked on origin, so the interrupted session finished it"
    return 0
  fi

  if lock_holder_is_alive "$(record_field host_pid)" "$(record_field snapshot)" \
     || session_container_is_running; then
    resume_stop "an earlier session of $UNIT is still running; ${phase:-its phase} is in flight in $wt" || return 1
    return 0
  fi

  # `unknown` is a tip the launching run could not read: not empty, not a sha, so neither remote
  # guard can run against it. A session may have pushed under it; refusing is the only answer that
  # cannot resume onto a branch someone else has moved.
  if [ "$tip" = unknown ]; then
    resume_stop "the run that launched ${phase:-that session} could not read origin, so where $BRANCH stood is unrecorded; $(unit_tree_advice)" || return 1
    return 0
  fi

  if [ -n "$tip" ]; then
    # An unreadable origin is not a deleted branch. `ls-remote` answers 0 and nothing for a branch
    # that is gone, and non-zero when it could not ask -- and the two want opposite reactions.
    if ! listing="$(git ls-remote --heads origin "$BRANCH" 2>/dev/null)"; then
      resume_stop "origin could not be read while ${phase:-a session} was in flight, so whether $BRANCH still exists is unknown; re-run when origin is reachable" || return 1
      return 0
    fi
    current="$(printf '%s\n' "$listing" | awk '{ print $1 }')"
    if [ -z "$current" ]; then
      resume_stop "$BRANCH is gone from origin while ${phase:-a session} was in flight; $(unit_tree_advice)" || return 1
      return 0
    fi
    # Any non-zero reads as "not an ancestor", including the 128 for a sha a force-push made
    # unreachable: someone advanced this branch under a session that is still holding the worktree.
    if ! git merge-base --is-ancestor "$tip" "$current" 2>/dev/null; then
      resume_stop "$BRANCH moved under an interrupted session ($tip is not in $current); $(unit_tree_advice)" || return 1
      return 0
    fi
  fi

  if [ -z "$id" ]; then
    resume_fresh "the interrupted session left no id to resume"
    return 0
  fi

  # The record has to name the work this run is about to do. A record for some other phase is a
  # record the branch has moved past, and resuming it would hand a session the wrong prompt. A
  # closing step's record is honoured when every phase is ticked and the step is one of ours.
  next="$(next_phase)"
  want="${next%%|*}"
  if [ -z "$want" ]; then
    case " $CLOSING_STEPS " in
      *" $step "*) want="closing:$step" ;;
      *)           want="closing:$(next_closing_step)" ;;
    esac
  fi
  if [ "$phase" != "$want" ]; then
    resume_fresh "the record names ${phase:-nothing} but $want is what is owed"
    return 0
  fi

  if [ "$RESUME_REPORT" = 1 ]; then
    log "resume: $phase from session $id"
    return 0
  fi

  [ -z "$step" ] || mark_closing_steps_before "$step"
  RESUME_ID="$id"
  log "$UNIT: continuing the interrupted session for $phase in $wt"
  return 0
}

# The two ways the decision above ends badly, each said once. In report-only mode neither of them
# acts: the reason is printed under the same `resume:` prefix as a decision that succeeded, and the
# caller carries on as if there had been no record at all.
resume_fresh() {
  if [ "$RESUME_REPORT" = 1 ]; then
    log "resume: none ($1)"
  else
    log "$UNIT: $1; starting fresh"
    drop_record
  fi
}

# Returns 1 only on the run path, where a resume into a worktree that may still have a writer, or
# onto a branch that moved under it, is a question for a human. Reporting one is not.
resume_stop() {
  if [ "$RESUME_REPORT" = 1 ]; then
    log "resume: none ($1)"
    return 0
  fi
  escalate "$UNIT" "$1"
  return 1
}

# ---------------------------------------------------------------------------- unit helpers

checkout_worktree() {
  local wt="$1" branch="$2"
  if git rev-parse --verify --quiet "$branch" >/dev/null; then
    with_config_lock git worktree add "$wt" "$branch"
  else
    with_config_lock git worktree add -b "$branch" "$wt" "origin/$branch"
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
# GitHub's own verdict on whether the PR can merge. DIRTY is a conflict with main; anything the
# read cannot answer is UNKNOWN, which is not a finding.
pr_merge_state() {
  gh pr view "$1" --json mergeStateStatus --jq .mergeStateStatus 2>/dev/null || echo UNKNOWN
}

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

# The skills a phase names are the host's own -- its scaffolds, its test runners, its checks -- and
# the spec resolved them at gate 1, where a human read the list. They ride in the prompt so a fresh
# session invokes them by instruction rather than by noticing them in its skill list.
phase_skills() {
  local phase="$1" tmp="$PHASES.spec" out rc=0
  spec_on_branch "$tmp"
  out="$("$LOOP_DIR/parse-ledger.sh" "$tmp" --skills "$phase" 2>"$PHASES.err")" || rc=$?
  rm -f "$tmp"
  if [ "$rc" != 0 ]; then
    warn "$UNIT: the Skills line of $phase does not parse, so the session is told none: $(head -1 "$PHASES.err")"
    return 0
  fi
  printf '%s\n' "$out" | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 }'
}

phase_prompt() {
  local spec="$1" unit="$2" branch="$3" phase="$4" title="$5" status_file="$6" skills="${7:-}"
  local skills_block=""
  if [ -n "$skills" ]; then
    skills_block="Skills: $skills
        the host's own skills this phase names. Invoke each one BEFORE writing code: they are how
        this repository scaffolds, tests and checks what the phase builds, and /implement-spec
        treats the list as binding."
  fi
  cat <<PROMPT
You are implementing exactly one phase of an approved spec, unattended, on a branch that already
carries the phases before it.

Spec:   $spec
Unit:   $unit - branch $branch
Phase:  $phase — $title
Base:   all diffs, gates and reviews for this unit are against $UNIT_BASE, never main.
$skills_block

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

# The three closing steps share one prompt shape; the step's own instructions and its sentinel word
# differ. docs and review hand over with CONTINUE; archive finishes with OK.
closing_step_block() {
  case "$1" in
    docs) cat <<BLOCK
Your step: the context docs. Run /sync-context-docs against $UNIT_BASE so the AGENTS.md / CLAUDE.md
nearest to every directory this unit touched describes the code as it now is. Commit and push
anything it changes. If nothing needed changing, push nothing: the branch tip is still what you
report.
BLOCK
    ;;
    review) cat <<BLOCK
Your step: the code review. The docs are already synced. Run /code-review over
  git diff \$(git merge-base "$UNIT_BASE" HEAD)...HEAD
with the reviewers on opus. Resolve every Critical and High finding in one fix wave; commit and
push it. Then /run-gates $UNIT_BASE in the foreground until every in-scope gate is green, and one
scoped re-review of the fix diff; commit and push. A finding you cannot resolve without a human is
an ESCALATE, not a note in the PR.

The fix wave edits the unit's own code and tests. A finding against a host skill, an AGENTS.md or
another doc beyond what the spec names is written into the review as a proposal and left alone:
the user approved the spec's scope at gate 1, and a doc change they did not approve is not yours
to make.
BLOCK
    ;;
    archive) cat <<BLOCK
Your step: the ledger. The docs are synced and the review is resolved. Run /archive-spec $SPEC: it
ticks this unit's line under ## Delivery and moves the spec to its implemented/ directory. Commit
and push.
BLOCK
    ;;
  esac
}

closing_prompt() {
  local spec="$1" unit="$2" branch="$3" step="$4" status_file="$5"
  local word="CONTINUE" meaning="this step is done and pushed; the next step runs in a fresh session"
  if [ "$step" = archive ]; then
    word="OK"
    meaning="the unit is reviewed, ticked and pushed"
  fi
  cat <<PROMPT
Every phase of an approved spec is built and ticked on this branch. The unit is closed in three
steps, each in its own session; you run exactly one of them, unattended, and stop before the PR.

This is a headless session. The moment you end your turn the process exits, and anything not pushed
is invisible to the loop. So nothing runs in the background -- run gates and reviewers in the
foreground and wait for them -- and commit and push before you write the sentinel.

Spec:   $spec
Unit:   $unit - branch $branch
Step:   $step
Base:   all diffs, gates and reviews for this unit are against $UNIT_BASE, never main.

$(closing_step_block "$step")

Do NOT open a pull request: the run opens it once it has re-run the gates itself. Do not run the
other closing steps; each has its own session.

The last thing you do, after the final push, is write exactly one line to this file
  $status_file
That line is one of:
  $word $branch <the sha you pushed> $RUN_ID
                              $meaning
  ESCALATE:<one-line reason>  for anything else.
Never leave it unwritten. A missing file is treated as an escalation.
PROMPT
}

# The session being resumed already has its original prompt: `--resume` restores the conversation,
# so this one does not restate the phase's instructions. It says what happened, where the work
# actually stands, and what to write on the way out -- and it names THIS run's id, because the
# sentinel is checked against the run that reads it and the session is carrying the one it was given
# the night it started. The sentinel block is the session's kind and nothing else, because the run id
# is read as the last field of that line.
continuation_prompt() {
  local spec="$1" unit="$2" branch="$3" phase="$4" title="$5" status_file="$6" step="${7:-}"
  local what doing word meaning

  if [ -n "$phase" ]; then
    what="Phase:  $phase — $title"
    doing="building $phase of $unit"
    word="CONTINUE"
    meaning="this phase is built, gated, ticked and pushed; the next session takes the next phase"
  else
    what="Step:   $step"
    doing="running the closing step '$step' of $unit"
    word="CONTINUE"
    meaning="this step is done and pushed; the next step runs in a fresh session"
    if [ "$step" = archive ]; then
      word="OK"
      meaning="the unit is reviewed, ticked and pushed"
    fi
  fi

  cat <<PROMPT
You were $doing on $branch and the session was interrupted: the usage limit, a signal, or a kill.
Nothing about the unit is wrong. The worktree is exactly as you left it.

Spec:   $spec
Unit:   $unit - branch $branch
$what
Base:   all diffs, gates and reviews for this unit are against $UNIT_BASE, never main.

Run \`git status\` and \`git log origin/$branch..HEAD\` first: they say what is committed, what is
not, and whether you had pushed. Continue from where the work actually stands, not from where you
remember it standing. Do not start over. The steps, the gates and the commit shape are the ones your
original prompt gave you, with one change: review every changed path before you keep or discard it,
and stage paths by name — never \`git add -A\` in a worktree another session wrote.
PROMPT

  [ -n "$phase" ] || cat <<'PROMPT'

The step may be half done: a fix wave half applied, the ledger line already ticked, the spec
already moved to its implemented/ directory. Re-derive each before redoing it; every closing step is
idempotent when you check first.
PROMPT

  [ -z "$phase" ] || printf '\n%s\n' "$(resolve_block)"

  cat <<PROMPT

Before exiting, write exactly one line to this file
  $status_file
That line is one of:
  $word $branch <the sha you pushed> $RUN_ID
                              $meaning
  ESCALATE:<one-line reason>  for anything else.
Never leave it unwritten; a missing file is treated as an escalation. The run id above is THIS
run's, not the one your original prompt carried.
PROMPT
}

# The conversation is gone but the work is not. This is the session's own prompt again -- there is
# no conversation left to continue -- with the one thing it could not otherwise know prepended: the
# tree it starts in is not clean, and the changes in it are its predecessor's. `git add -A` in that
# tree is how an interrupted session's half-finished edits get committed as though reviewed.
fallback_prompt() {
  cat <<'BLOCK'
A previous session of this unit worked in this worktree and is not being continued. Its work is on
disk, uncommitted, and possibly incomplete. Run `git status` first. Review every changed path before
you keep or discard it, and stage paths by name — never `git add -A` here.
BLOCK
  printf '\n%s\n' "$1"
}

# A `--resume` can fail for a reason that is not about the unit. The transcript the id names lives
# on disk -- pruned, wiped, or never persisted by a container -- and when it is gone the CLI exits
# before it reads the prompt: nothing on stdout, "No conversation found with session ID: <id>" on
# stderr (verified against claude 2.1.260 with a bogus id).
#
# A timeout is a session that ran, and a usage limit is a 429 the loop reports as a pause; both are
# excluded by name. A sentinel excludes it outright: the status file is removed before every session,
# so one that exists here was written by the session just launched -- proof the conversation resumed
# and ran. Without this, an `ESCALATE:` whose reason contains "not found" would classify as a dead
# transcript and the loop would re-spend the phase and bypass the human gate. The pattern reads the
# CLI's stderr only: a session's own summary can easily contain "not found".
resume_failed() {
  local rc="$1" json_file="$2"
  [ "$rc" != 124 ] || return 1
  ! hit_usage_limit "$json_file" || return 1
  [ ! -f "$UNIT_DIR/status" ] || return 1
  [ -s "$json_file" ] || return 0
  grep -qiE 'no conversation|not found|could not (find|resume)' "$json_file.err" 2>/dev/null
}

# ---------------------------------------------------------------------------- build

# settings.local.json is gitignored, so it is absent from every worktree the loop creates. The copy
# gives the session the permissions the human has already proved sufficient. The driver's first, the
# main checkout's as a fallback: a driver that is itself a worktree has none of its own.
cp_settings() {
  local wt="$1" src="$ROOT/.claude/settings.local.json"
  [ -f "$src" ] || src="$MAIN_ROOT/.claude/settings.local.json"
  mkdir -p "$wt/.claude"
  [ ! -f "$src" ] || cp "$src" "$wt/.claude/settings.local.json"
}

# One session. The worktree is continued when it exists, checked out when the branch exists on
# origin, and created from origin/main otherwise. A branch on origin is always the work of earlier
# sessions and is never rebuilt. A local branch that never reached origin is dropped only when it
# holds nothing beyond origin/main, which is what a session that never committed leaves behind; one
# that carries commits may be someone's work, so the loop stops and asks rather than deleting it.
#
# `label` is what the session record names: the phase, or `closing:<step>`. `fresh_prompt` is the
# prompt this session would have been given had there been nothing to resume; it is used for one
# thing, the fallback when the conversation named by RESUME_ID turns out not to exist.
run_session() {
  local prompt="$1" json_file="$2" label="$3" fresh_prompt="${4:-}"
  local wt="$UNIT_WT" rc

  if [ "$IN_PLACE" = 1 ]; then
    # The driver is the unit. Nothing to add, nothing to check out, and CURRENT_WT is deliberately
    # left empty -- it is what the done path reclaims by, and the one tree that must never be
    # reclaimed is the one this process is running in.
    :
  elif [ -d "$wt" ]; then
    # A kept worktree outlives the run that created it, so the driver's settings have to reach a
    # session that lands in one: copying them only where the worktree is created would pin a unit
    # built over more than one run to whatever permissions were current the night it started.
    CURRENT_WT="$wt"
    cp_settings "$wt"
  elif git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null; then
    checkout_worktree "$wt" "$BRANCH" || { escalate "$UNIT" "could not check out $BRANCH"; return 1; }
    CURRENT_WT="$wt"
    cp_settings "$wt"
  else
    if git rev-parse --verify --quiet "$BRANCH" >/dev/null; then
      if [ "$(git rev-list --count "origin/main..$BRANCH" 2>/dev/null || echo 1)" != 0 ]; then
        escalate "$UNIT" "a local branch $BRANCH carries commits that never reached origin; push it or delete it by hand"
        return 1
      fi
      git branch -D "$BRANCH" >/dev/null 2>&1 || true
    fi
    log "$UNIT: worktree $wt on $BRANCH from origin/main"
    if ! with_config_lock git worktree add -b "$BRANCH" "$wt" origin/main; then
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
    warn "A linked worktree's .git names an absolute path into the main repo. Both it and the"
    warn "repository's common git directory must be mounted, read-write -- git writes refs,"
    warn "objects and the index there."
    return 1
  fi

  # Written before the launch, because after it there may be no loop left to write anything: the
  # record is what survives a session the loop never hears back from. A continuation mints nothing:
  # `--resume` names a conversation that already has an id, and both launchers spell the flag as
  # `${SESSION_ID:+--session-id ...}`, so clearing SESSION_ID is how `--session-id` is dropped. The
  # record keeps naming the id being resumed, so a second interruption can resume it again.
  if [ -n "$RESUME_ID" ]; then
    SESSION_ID=""
  else
    mint_session_id
  fi
  write_session_record "$label"

  # A fresh session in a tree that is not clean is the fallback's situation under another name. It
  # happens whenever a kept worktree is reused without a resume -- the record was dropped because the
  # session that made the mess reported an `ESCALATE:`, or named a phase the branch has moved past.
  # Its own prompt would tell it to `git add -A`, which is how a predecessor's half-finished work
  # lands, unreviewed, in this phase's one commit.
  if [ -z "$RESUME_ID" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    log "$UNIT: $wt has uncommitted work from an earlier session; the session is told to stage by name"
    prompt="$(fallback_prompt "$prompt")"
  fi

  run_claude "$wt" "$prompt" "$json_file" "$LOOP_MODEL"
  rc=$?
  [ "$rc" = 124 ] && { escalate "$UNIT" "timed out after ${UNIT_TIMEOUT}s"; return 1; }

  # A dead transcript is not a dead unit. The resume failed before the session started, so nothing
  # was spent and nothing was decided -- escalating here would hand a human a worktree full of work
  # and no way to continue it but by hand. The same worktree, the session's own prompt, and a new id.
  if [ -n "$RESUME_ID" ] && [ -n "$fresh_prompt" ] && resume_failed "$rc" "$json_file"; then
    warn "$UNIT: session $RESUME_ID could not be resumed; starting a fresh session on its work in $wt"
    RESUME_ID=""
    mint_session_id
    # Rewritten, not appended to: the record names one conversation, and after this line it has to
    # name the new one -- a second interruption resumes what actually ran.
    write_session_record "$label"
    run_claude "$wt" "$(fallback_prompt "$fresh_prompt")" "$json_file" "$LOOP_MODEL"
    rc=$?
    [ "$rc" = 124 ] && { escalate "$UNIT" "timed out after ${UNIT_TIMEOUT}s"; return 1; }
  fi
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
#   - The repository's common .git is mounted because a linked worktree's `.git` is a file pointing
#     into it by absolute path -- whether the worktree is one the loop created or the one it was
#     driven from. The socket already grants host root, so this widens nothing that matters; what
#     the sandbox bounds is lateral reach: ~/.ssh, the host home, other repositories, the gh login.
#   - The unit's directory is mounted, and only it, because the sentinel lives outside the worktree
#     and two units building at once must not read each other's. Its claude-config/ is the CLI's
#     config dir inside the container, so the transcript a `--resume` needs outlives the container.
#   - It runs as the invoking uid so the worktree stays owned by the human who reviews it.
#
# The container has no ssh keys, so git must speak https. An ssh remote is rewritten to
# https://x-access-token:$GH_TOKEN@github.com/ through git's own url.<base>.insteadOf, passed as
# environment rather than written to any config file. The ssh prefix is taken from the actual remote
# because it may be a per-user ssh alias rather than a hostname.
# owner/repo as GitHub names it, from the origin remote in any of its spellings.
origin_nwo() {
  local url
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  url="${url%.git}"; url="${url%/}"
  case "$url" in
    *://*) url="${url#*://}"; url="${url#*@}"; url="${url#*/}" ;;
    *:*)   url="${url#*:}" ;;
  esac
  printf '%s' "$url"
}

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

  # Docker refuses to start while the cid file is there, and `--rm` never deletes it -- so without
  # this the launch after a kill, the one this whole design exists for, fails before a token is
  # spent. Everything that reads the cid (the resume decision, the teardown) has read it by here.
  rm -f "$UNIT_DIR/cid"

  # Named, init'd and writing its id, so a container that outlives the loop can be found and killed:
  # `docker ps --filter name=delivery-loop-` for a human, the cid file for the teardown. `--init`
  # reaps the CLI's own children when the container is killed. The name carries the timestamp, the
  # pid and a per-run container ordinal: a re-run of a paused unit can start inside the same second
  # as the run it continues, and the PR-opening launch shares the last closing session's number.
  CONTAINER_N=$((CONTAINER_N + 1))
  "$TIMEOUT_BIN" "$UNIT_TIMEOUT" docker run --rm -i --init \
    --name "delivery-loop-$BRANCH-${RUN_ID#*-}-${RUN_ID%%-*}-$(printf '%02d' "$CONTAINER_N")" \
    --cidfile "$UNIT_DIR/cid" \
    -u "$(id -u):$(id -g)" \
    ${LOOP_SOCK_GID:+--group-add "$LOOP_SOCK_GID"} \
    -v "$wt:$wt" \
    -v "$GIT_COMMON:$GIT_COMMON" \
    -v "$UNIT_DIR:$UNIT_DIR" \
    -v "$UNIT_DIR/claude-config:/loop-config" \
    -v "$PLUGIN_ROOT:$PLUGIN_ROOT:ro" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -w "$wt" \
    -e CLAUDE_CODE_OAUTH_TOKEN -e ANTHROPIC_API_KEY -e GH_TOKEN \
    ${SANDBOX_GIT_ENV[@]+"${SANDBOX_GIT_ENV[@]}"} \
    "$LOOP_IMAGE" \
      -p "$prompt" \
      --model "$model" \
      --plugin-dir "$PLUGIN_ROOT" \
      ${SESSION_ID:+--session-id "$SESSION_ID"} \
      ${RESUME_ID:+--resume "$RESUME_ID"} \
      --output-format json \
      --permission-mode bypassPermissions \
      --disallowedTools "${LOOP_DENIALS[@]}" > "$json_file" 2>"$json_file.err" || rc=$?
  return "$rc"
}

# A session's context is the input of its last recorded API call: cache reads plus cache creation
# plus fresh input. The result's `usage.iterations` holds one entry, that call; the max is taken in
# case a CLI ever records more. It is the window the model actually held at the end, which is what
# says whether a phase fits in one session.
#
# The alarm compares it to half the model's context window unless the user set a token count. A
# fixed default fires on every phase of a host with a large docs tree on a large-window model: a
# five-turn session on such a host held 224k before it had done anything, and 150k said "phase too
# large" about every phase of a unit whose phases were fine. Half the window is host-independent, and
# a phase that fills half of it is too large whatever the host. Unset in loop.env means "half".
CONTEXT_TOTAL_JQ='(.cache_read_input_tokens//0) + (.cache_creation_input_tokens//0) + (.input_tokens//0)'

session_context() {
  jq -r "([.usage.iterations[]? | $CONTEXT_TOTAL_JQ] | max) // 0" "$1" 2>/dev/null || echo 0
}

# The largest window among the models the session used: the build model's, the one the main
# conversation ran on. Subagents on a smaller model show up beside it and must not shrink the alarm.
context_alarm_for() {
  local json_file="$1" window
  if [ -n "$SESSION_CONTEXT_ALARM" ]; then
    printf '%s' "$SESSION_CONTEXT_ALARM"
    return
  fi
  window="$(jq -r '([.modelUsage[]?.contextWindow // 0] | max) // 0' "$json_file" 2>/dev/null || echo 0)"
  printf '%s' "$(( ${window:-0} / 2 ))"
}

context_alarm() {
  local json_file="$1" label="$2" context alarm
  [ -s "$json_file" ] || return 0
  context="$(session_context "$json_file")"
  alarm="$(context_alarm_for "$json_file")"
  [ "${alarm:-0}" -gt 0 ] 2>/dev/null || return 0
  if [ "$context" -gt "$alarm" ] 2>/dev/null; then
    if [ -n "$SESSION_CONTEXT_ALARM" ]; then
      warn "$label: context $context exceeds SESSION_CONTEXT_ALARM=$alarm -- this phase is cut too large"
    else
      warn "$label: context $context exceeds half the model window ($alarm) -- this phase is cut too large"
    fi
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
    -v "$GIT_COMMON:$GIT_COMMON" \
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
      ${SESSION_ID:+--session-id "$SESSION_ID"} \
      ${RESUME_ID:+--resume "$RESUME_ID"} \
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
# `kind` is `phase` with the phase label, or `closing` with the step name. A phase session and the
# docs and review steps hand over with CONTINUE; only the archive step may write OK.
#
# The sentinel decides whether the record survives. A session that wrote one reported on itself: it
# either finished its work or is finished and wrong, and in both cases there is no conversation
# worth resuming, so the record goes. A session that wrote none was interrupted -- the usage limit,
# a signal, a kill, a timeout, a denied `Write` -- and its half-built work is in the worktree with
# nothing but the record to name it, so the record stays. `is_error` counts as interrupted.
#
# Returns 0 for a verified OK, 2 for a verified CONTINUE, 3 for a usage-limit pause, 4 for a clean
# exit that wrote no sentinel while its record still stands (the caller resumes it once), 1 otherwise.
verify_session() {
  local kind="$1" name="$2" json_file="$3"
  local status_file="$UNIT_DIR/status"
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
    [ ! -f "$status_file" ] || drop_record
    return 1
  fi

  # A clean exit with no sentinel is a session that ended its turn early -- it asked a question, or
  # backgrounded its gates and waited for a next turn a headless session does not have. Its work is
  # in the worktree and its record names its conversation; that is exactly the state a re-run
  # resumes, so the loop resumes it itself, once. A kill leaves no JSON and is not this case.
  if [ ! -f "$status_file" ]; then
    if [ -s "$json_file" ] && [ -f "$UNIT_DIR/session" ] \
       && [ "$(jq -r '.is_error // false' "$json_file" 2>/dev/null)" != "true" ]; then
      return 4
    fi
    escalate "$UNIT" "no sentinel was written; treating as an escalation"
    return 1
  fi
  sentinel="$(cat "$status_file")"

  case "$sentinel" in
    ESCALATE:*) escalate "$UNIT" "${sentinel#ESCALATE:}"; drop_record; return 1 ;;
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

  # Past here the session both reported itself and was not cut off, so every outcome below is one it
  # owns. The one conversation the loop could have resumed is over.
  drop_record

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
  # from the checklist on origin, not from its say-so. A closing step runs with every phase ticked,
  # and the archive step's OK is read from the ledger line, not from its say-so either. The wrong
  # sentinel for the session's kind is an escalation.
  if ! refresh_phases; then
    escalate "$UNIT" "the ## Progress checklist on origin/$BRANCH no longer parses: $(head -1 "$PHASES.err")"
    return 1
  fi
  if [ "$kind" = phase ]; then
    [ "$handover" = 1 ] || { escalate "$UNIT" "a phase session wrote OK; only the closing archive step may"; return 1; }
    if ! phase_is_ticked "$name"; then
      escalate "$UNIT" "the session handed over without ticking $name in ## Progress"
      return 1
    fi
    return 2
  fi
  if [ "$(unticked_phases)" != 0 ]; then
    escalate "$UNIT" "the closing step '$name' ran with $(unticked_phases) phase(s) still unticked in ## Progress"
    return 1
  fi
  if [ "$name" = archive ]; then
    [ "$handover" = 0 ] || { escalate "$UNIT" "the closing session handed over instead of finishing"; return 1; }
    if ! unit_is_ticked; then
      escalate "$UNIT" "the archive step wrote OK but $UNIT is not ticked under ## Delivery on origin/$BRANCH"
      return 1
    fi
    return 0
  fi
  [ "$handover" = 1 ] || { escalate "$UNIT" "the closing step '$name' wrote OK; only the archive step may"; return 1; }
  return 2
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
    if run_gates "$UNIT_WT"; then
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
#
# The list is split into an array and each gate runs on an empty stdin. A gate is a child process
# that inherits the loop's stdin, and a real `make lint` reads it -- `docker compose` does -- so a
# list fed to `read` through a heredoc lost every line after the first gate consumed it: `make lint`
# ate `make test`, and the unit was reported green on lint alone. The closing line names every gate
# that ran, so a gate that did not is visible in the log rather than inferred from its absence.
run_gates() {
  local wt="$1" gate
  local -a gates=() ran=()
  IFS=';' read -r -a gates <<< "$LOOP_GATES"
  for gate in "${gates[@]}"; do
    [ -n "$gate" ] || continue
    log "$UNIT: gate: $gate"
    ( cd "$wt" && bash -c "$gate" </dev/null ) || return 1
    ran+=("$gate")
  done
  log "$UNIT: ${#ran[@]} gates green: $(printf '%s; ' "${ran[@]}" | sed 's/; $//')"
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
  local tmp rc=1
  tmp="$(ledger_of_branch)"
  grep -qE "^- \\[[xX]\\][[:space:]]+\\*\\*$UNIT\\*\\*.* → [0-9]+ lines" "$tmp" && rc=0
  rm -f "$tmp"
  [ "$rc" = 0 ] || return 1
  # The telemetry is written once before the PR, for its body, and again after it with the number.
  # Only the second write is the record; the first must not read as "already recorded".
  grep -q '^| PR | #' "$(telemetry_file)" 2>/dev/null
}

# The telemetry is the loop's record, kept beside its state and summarised in the PR body: a host
# repository does not carry a file for the engine's sake.
telemetry_file() {
  printf '%s/telemetry/%s/%s.md' "$STATE_DIR" "$(basename "$SPEC" .md)" "$(printf '%s' "$UNIT" | tr ' /' '--')"
}

# What a unit cost to build, one row per session. Context is what a session costs, and recording
# each session's context beside the alarm is what shows which phase was cut too large.
record_telemetry() {
  local pr_number="$1" measured="$2"
  local file json rows=""

  file="$(telemetry_file)"
  mkdir -p "$(dirname "$file")"

  # Session files are named so a lexical glob is chronological across runs.
  for json in "$STATE_DIR/$BRANCH".s*.json; do
    [ -s "$json" ] || continue
    # A session refused before it started built nothing and has no row.
    [ "$(jq -r '.is_error // false' "$json" 2>/dev/null)" != "true" ] || continue
    rows="$rows$(jq -r --arg alarm "$(context_alarm_for "$json")" "
      (([.usage.iterations[]? | $CONTEXT_TOTAL_JQ] | max) // 0) as \$context
      | \"| \" + (.loop_phase // \"closing\") + \" | \" + (.num_turns|tostring)
        + \" | \" + (\$context|tostring) + (if (\$alarm|tonumber) > 0 and \$context > (\$alarm|tonumber) then \" ⚠\" else \"\" end)
        + \" | \" + ((.duration_ms/60000|round)|tostring) + \" min | \" + ((.modelUsage | keys | join(\", \")) // \"?\") + \" |\"
    " "$json" 2>/dev/null || true)
"
  done

  # The backticks are markdown, not command substitution.
  # shellcheck disable=SC2016
  {
    printf '# %s — `%s`\n\n' "$UNIT" "$BRANCH"
    printf '| | |\n|---|---|\n'
    # Before the PR exists there is no row to write; the PR body carries the table and must not
    # show an empty cell. unit_is_recorded reads the row's presence as "the PR is recorded".
    [ -z "$pr_number" ] || printf '| PR | #%s |\n' "$pr_number"
    printf '| size | %s |\n' "$measured"
    printf '| context alarm | %s |\n\n' "${SESSION_CONTEXT_ALARM:-half the model window}"
    # No cost column: context is the number that says whether the phasing held, and a notional
    # API-equivalent beside it is read as a bill nobody pays.
    printf '| session | turns | context | wall clock | model |\n|---|---|---|---|---|\n'
    printf '%s' "$rows"
  } > "$file"
}

# Idempotent: a restarted run leaves the ledger ticked exactly once.
record_unit() {
  local pr_number="$1"
  local wt="$UNIT_WT"
  local measured line spec_in_wt

  if unit_is_recorded; then
    log "$UNIT is already recorded"
    return 0
  fi

  # The loop can crash between /open-pr and this commit, leaving an open PR whose unit is unticked
  # and whose worktree is gone. The tick belongs on the unit's branch, so check it out again. In
  # place the worktree is the driver and is always there.
  if [ "$IN_PLACE" = 0 ] && [ ! -d "$wt" ]; then
    log "$UNIT: no worktree; checking $BRANCH out to record the tick"
    checkout_worktree "$wt" "$BRANCH" >/dev/null 2>&1 \
      || { escalate "$UNIT" "ledger is unticked and $BRANCH cannot be checked out; tick it by hand"; return 1; }
    CURRENT_WT="$wt"
  fi

  measured="$( cd "$wt" && "$LOOP_DIR/unit-size.sh" origin/main || true )"
  line="$measured"
  [ -n "$pr_number" ] && line="$line (#$pr_number)"

  record_telemetry "$pr_number" "$measured"

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
    && git add "$spec_in_wt" \
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
  if [ "$IN_PLACE" = 1 ]; then
    log "tree:   $UNIT_WT — this worktree, built in place and never reclaimed"
  else
    log "tree:   $UNIT_WT — created for the unit, reclaimed when it is done"
  fi
  log "state:  $(probe_run "$BRANCH")"
  log "phases: $PHASE_COUNT, one session each, then 3 closing sessions: docs, review, archive (MAX_SESSIONS=$MAX_SESSIONS)"
  local skills
  while IFS='|' read -r done_flag phase title; do
    [ -n "$phase" ] || continue
    printf '  [%s] %s — %s\n' "$done_flag" "$phase" "$title"
    skills="$(phase_skills "$phase")"
    [ -z "$skills" ] || printf '      skills: %s\n' "$skills"
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
  log "bounds: MAX_SESSIONS=${MAX_SESSIONS:-—} UNIT_TIMEOUT=${UNIT_TIMEOUT}s SESSION_CONTEXT_ALARM=${SESSION_CONTEXT_ALARM:-half-window}"
  log "gates:  ${LOOP_GATES:-none} (${LOOP_GATES_FROM#"$ROOT"/})"
  [ -z "$LOOP_CLEAN_WORKTREE" ] || log "cleanup: $LOOP_CLEAN_WORKTREE, inside the worktree before it is removed"
  [ -z "$LOOP_SIZE_EXCLUDES" ]  || log "excludes: $LOOP_SIZE_EXCLUDES"
  [ -z "$LOOP_DENIALS_EXTRA" ]  || log "denials: $LOOP_DENIALS_EXTRA, beyond the built-in list"
  log "models: build sessions on $LOOP_MODEL, the PR session on $PR_MODEL"
  if [ "$LOOP_SANDBOX" = "1" ]; then
    log "sandbox: ON — sessions run in $LOOP_IMAGE"
  else
    log "sandbox: OFF — sessions run on this host, with your ssh keys and gh login"
  fi
  log "timeout: $TIMEOUT_BIN"
  print_plan
  # What the next run would do with what the last one left, said before it is done. A paused unit's
  # kept worktree and its record are invisible from the outside, so a dry run that reported the plan
  # and not the resume would describe a run that starts at phase one when it would in fact continue
  # a session. Report-only: this reads and changes nothing.
  [ -z "$BRANCH" ] || resume_decision --report
  rm -f "$LEDGER" "$PHASES" "$PHASES.err"
  exit 0
fi

if [ -z "$BRANCH" ]; then
  rm -f "$LEDGER" "$PHASES" "$PHASES.err"
  exit 0
fi

if ! acquire_lock "$BRANCH"; then
  exit 3
fi
# HUP is not optional for an overnight run. It arrives when the SSH session that started the loop
# drops, and without it the trap never fires: the lock stays held and the session container keeps
# running with the worktree mounted.
trap teardown EXIT INT TERM HUP

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
#
# In place the branch may not be on origin yet -- the spec's own commits are the only ones it has,
# and the first session's push is what creates it -- so the merge base is taken against HEAD, which
# is that branch. It is the same commit either way once the push has happened.
if [ "$IN_PLACE" = 1 ]; then
  UNIT_BASE="$(git merge-base origin/main HEAD 2>/dev/null || git rev-parse origin/main)"
else
  UNIT_BASE="$(git merge-base origin/main "origin/$BRANCH" 2>/dev/null || git rev-parse origin/main)"
fi

# What the last run left, read before this one starts anything. After the PR probe -- a merged or
# closed PR is a fact about the whole unit and outranks any question about one interrupted session
# -- and before the first session, because its answer decides which prompt that session gets. It
# either sets RESUME_ID, drops a record that no longer describes anything, or escalates because the
# worktree may still have a writer.
if ! resume_decision; then
  exit 4
fi

# One phase per session, as many sessions as there are phases, then one per closing step. The gates
# run in every session on that session's work; `prove_unit` runs them once more on the host when the
# archive step says OK.
SESSIONS=0
UNIT_OK=0
PR_CONFLICTS=0
STEP=""
# The one phase or step whose silent exit has already been resumed. A second silent exit of the same
# one is an escalation: the conversation was given its turn back and ended it the same way.
SILENT_RESUMED=""
while :; do
  if [ "$SESSIONS" -ge "$MAX_SESSIONS" ]; then
    escalate "$UNIT" "still not finished after $SESSIONS sessions (MAX_SESSIONS=$MAX_SESSIONS); it is not converging"
    break
  fi
  SESSIONS=$((SESSIONS + 1))
  STATUS_FILE="$UNIT_DIR/status"
  # Epoch, then pid, then the session number: a lexical glob is chronological across runs, and two
  # runs started within the same second cannot overwrite each other's sessions -- a re-run after a
  # pause no longer waits for a worktree to be created and can start inside the same second.
  JSON_FILE="$STATE_DIR/$BRANCH.s${RUN_ID#*-}-$$-$(printf '%02d' "$SESSIONS").json"
  rm -f "$STATUS_FILE"

  # A resumed session is tagged in the telemetry rather than bounded: it starts near the context its
  # interrupted half reached, and that row is a reading like every other. Captured here because
  # RESUME_ID is cleared the moment the session it belongs to has been launched.
  RESUMED=""
  [ -z "$RESUME_ID" ] || RESUMED=" (resumed)"

  NEXT="$(next_phase)"
  if [ -n "$NEXT" ]; then
    PHASE="${NEXT%%|*}"
    TITLE="${NEXT#*|}"
    FRESH="$(phase_prompt "$SPEC" "$UNIT" "$BRANCH" "$PHASE" "$TITLE" "$STATUS_FILE" "$(phase_skills "$PHASE")")"
    if [ -n "$RESUME_ID" ]; then
      log "$UNIT: session $SESSIONS continues the interrupted $PHASE — $TITLE"
      run_session "$(continuation_prompt "$SPEC" "$UNIT" "$BRANCH" "$PHASE" "$TITLE" "$STATUS_FILE")" \
                  "$JSON_FILE" "$PHASE" "$FRESH" || break
    else
      log "$UNIT: session $SESSIONS builds $PHASE — $TITLE"
      run_session "$FRESH" "$JSON_FILE" "$PHASE" || break
    fi
  elif unit_is_ticked; then
    SESSIONS=$((SESSIONS - 1))
    log "$UNIT: every phase is ticked and the ledger is ticked on $BRANCH; the unit is closed"
    if [ "$IN_PLACE" = 0 ]; then
      if [ ! -d "$UNIT_WT" ]; then
        checkout_worktree "$UNIT_WT" "$BRANCH" >/dev/null 2>&1 \
          || { escalate "$UNIT" "could not check out $BRANCH to prove and record it"; break; }
        cp_settings "$UNIT_WT"
      fi
      CURRENT_WT="$UNIT_WT"
    fi
    UNIT_OK=1
    break
  else
    PHASE=""
    STEP="$(next_closing_step)"
    FRESH="$(closing_prompt "$SPEC" "$UNIT" "$BRANCH" "$STEP" "$STATUS_FILE")"
    if [ -n "$RESUME_ID" ]; then
      log "$UNIT: session $SESSIONS continues the interrupted closing step '$STEP'"
      run_session "$(continuation_prompt "$SPEC" "$UNIT" "$BRANCH" "" "" "$STATUS_FILE" "$STEP")" \
                  "$JSON_FILE" "closing:$STEP" "$FRESH" || break
    else
      log "$UNIT: session $SESSIONS runs the closing step '$STEP'"
      run_session "$FRESH" "$JSON_FILE" "closing:$STEP" || break
    fi
  fi
  # One session is resumed, not the run. Whatever the continuation reported, the conversation it
  # continued has now had its say; the next session is a fresh one on the next phase.
  RESUME_ID=""
  # The phase or step is stamped into the session's JSON so the telemetry can name it. The latest
  # session is also kept under the plain branch name, which is where a human reads it after an
  # escalation.
  LABEL="${PHASE:-closing:$STEP}"
  if [ -s "$JSON_FILE" ] && jq --arg p "$LABEL$RESUMED" '. + {loop_phase: $p}' "$JSON_FILE" > "$JSON_FILE.tmp" 2>/dev/null; then
    mv "$JSON_FILE.tmp" "$JSON_FILE"
  fi
  rm -f "$JSON_FILE.tmp"
  cp "$JSON_FILE" "$STATE_DIR/$BRANCH.json" 2>/dev/null || true
  context_alarm "$JSON_FILE" "$LABEL"

  VERDICT=0
  if [ -n "$PHASE" ]; then
    verify_session phase "$PHASE" "$JSON_FILE" || VERDICT=$?
  else
    verify_session closing "$STEP" "$JSON_FILE" || VERDICT=$?
  fi
  case "$VERDICT" in
    0) UNIT_OK=1; break ;;
    2)
      if [ -n "$PHASE" ]; then
        log "$UNIT: $PHASE is ticked and pushed; continuing in a fresh session"
      else
        CLOSING_DONE="$CLOSING_DONE $STEP"
        log "$UNIT: closing step '$STEP' is done and pushed; continuing in a fresh session"
      fi
      ;;
    3) PAUSED=1; break ;;
    4)
      if [ "$SILENT_RESUMED" != "$LABEL" ]; then
        SILENT_RESUMED="$LABEL"
        RESUME_ID="$(sed -n 's/^session_id=//p' "$UNIT_DIR/session" | head -1)"
        if [ -n "$RESUME_ID" ]; then
          # The continuation is the same session given its turn back, not a new attempt at the
          # phase, so it does not count against MAX_SESSIONS and it takes the same session number.
          SESSIONS=$((SESSIONS - 1))
          log "$UNIT: $LABEL exited clean with no sentinel; resuming that conversation once"
          continue
        fi
      fi
      escalate "$UNIT" "$LABEL exited clean with no sentinel twice: resumed once, and ended its turn the same way"
      break
      ;;
    *) break ;;
  esac
done

if [ "$UNIT_OK" = 1 ] && prove_unit; then
  # Nothing below this line is a continuation of anything. The unit reached here either through the
  # archive step or through the short-circuit that finds its ledger already ticked -- and on that
  # second path no session ran, so a RESUME_ID set for one would still be standing.
  RESUME_ID=""
  # One PR for the whole unit, opened once and attested on origin: a session can exit 0 having
  # opened nothing.
  if [ "$(probe_run "$BRANCH")" = "NONE" ]; then
    log "opening the PR for $UNIT on $BRANCH"
    # An id of its own, and no record: nothing about a session that reads a diff and fills in a
    # template is worth resuming, and reusing the last session's id would have the CLI refuse.
    mint_session_id
    # The telemetry is written before the PR so its table can go in the PR body -- the repository
    # carries no telemetry file -- and rewritten afterwards with the PR number.
    record_telemetry "" "$( cd "$UNIT_WT" && "$LOOP_DIR/unit-size.sh" origin/main || true )"
    run_claude "$UNIT_WT" \
      "Run /open-pr with --base main. This branch carries the whole delivery unit $UNIT of $SPEC, one
commit per phase. Title it: <type>(<scope>): <the feature>. Do not list the phases in the title.
The per-session telemetry of this unit is the markdown table in $(telemetry_file); put it in the
PR body under a '## Sessions' heading, as it is." \
      "$STATE_DIR/$BRANCH.pr.json" "$PR_MODEL" || escalate "$UNIT" "/open-pr failed"
    # One probe answers both questions: is there a PR, and what is its number.
    PR_STATE="$(probe_run "$BRANCH")"
    case "$PR_STATE" in
      OPEN\ *|MERGED\ *|CLOSED\ *) PR_NUMBER="${PR_STATE#* }" ;;
      NONE)  escalate "$UNIT" "the PR was reported open but origin has none for this branch; open it by hand" ;;
      *)     escalate "$UNIT" "gh could not be read after /open-pr; check whether the PR exists by hand" ;;
    esac
  fi

  # Recorded after the PR so the tick carries its number. The tick is what a later run reads to
  # know the unit is delivered, so it is written even when the PR step escalated.
  record_unit "$PR_NUMBER" || true

  # A unit built and green can still be unable to merge: main moved under a long build. Said in the
  # log the run ends with rather than discovered in the GitHub UI. The fix is a human's -- merge
  # origin/main into the branch, resolve with judgement, run the gates, push -- because it is a
  # decision over conflicts no session saw, and a merge needs no force-push where a rebase would.
  if [ -n "${PR_NUMBER:-}" ] && [ "$(pr_merge_state "$PR_NUMBER")" = "DIRTY" ]; then
    PR_CONFLICTS=1
    log "$UNIT: PR #$PR_NUMBER conflicts with main; merge origin/main into $BRANCH, resolve, run the gates and push before merging"
  fi

  # The only reclaim. The unit is proved, its PR is open and its tick is recorded, so nothing in the
  # worktree is owed to anyone. Every other way out of this script keeps it: that is the difference
  # between a run that finished and a run that stopped.
  #
  # Never in place. There the worktree is the driver -- the human's own tree, the branch's only
  # checkout, and the directory this process is running in. CURRENT_WT is never set on that path;
  # IN_PLACE is asserted beside it because this is the one line whose mistake is unrecoverable.
  drop_record
  if [ "$IN_PLACE" = 0 ] && [ -n "$CURRENT_WT" ] && [ -d "$CURRENT_WT" ]; then
    "$LOOP_DIR/reclaim-worktree.sh" "$CURRENT_WT" || warn "reclaim of $CURRENT_WT did not complete"
    CURRENT_WT=""
  fi
fi

log "$SESSIONS session(s) this run"

# A stop leaves a worktree behind, and a worktree nobody knows about is the disk disappearing for
# no stated reason. Said on the way out, with the phase the record names and the command that drops
# it, so keeping it is a choice rather than an accident.
KEPT_NOTE="$(kept_worktree_note)"
[ -z "$KEPT_NOTE" ] || log "$KEPT_NOTE"

if [ "$PAUSED" = 1 ]; then
  log "paused: the usage limit is reached. Re-run the same command once it resets; the loop continues"
  log "the refused session on $BRANCH, in the worktree it left."
  attention "delivery-loop: paused on the usage limit — re-run to continue $UNIT${KEPT_NOTE:+; $KEPT_NOTE}"
  exit 5
fi
[ "$ESCALATED" = 0 ] || exit 4
[ "$UNIT_OK" = 0 ] || attention "delivery-loop: $UNIT built, PR #${PR_NUMBER:-?} open and waiting for review$([ "$PR_CONFLICTS" = 1 ] && printf '; it conflicts with main')"
exit 0
