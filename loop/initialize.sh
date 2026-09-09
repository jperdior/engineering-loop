#!/usr/bin/env bash
#
# Set the engineering loop up for a user: where its sessions run, and the two credentials a
# container needs. Writes one of two settings files, same format, that the loop reads in this order,
# the first one winning key by key:
#
#   this repository's   <main checkout>/.git/engineering-loop/loop.env
#   the global one      ~/.config/engineering-loop/loop.env
#
# The repository's file lives under .git/ so it can never be committed and is shared by every
# worktree of the repository. It holds what differs for this repository -- another account, another
# mode; the global file holds the user's defaults. Two accounts on one machine is the case this
# covers: the global file for the usual one, a repository file for the other.
#
# Both tokens are minted through a browser, so a script cannot fetch them. What it can do is explain
# each one when it is asked for, write the values with the right file mode, and never echo them back.
# Idempotent: run it again to change one value and keep the rest.
#
# Usage:
#   initialize.sh                    interactive: container or host, for every repository or this
#                                    one, then the tokens a container needs
#   initialize.sh --show             what is configured, in both files, names only, and the mode
#                                    that results; never a value
#   initialize.sh --host --repo      record LOOP_SANDBOX=0 for this repository, no questions
#   initialize.sh --host --global    record LOOP_SANDBOX=0 for every repository, no questions
#
# LOOP_ENV names one file to read and write instead of the two above (for the tests).
#
# Exit: 0 written, 2 usage, 3 refused.

set -euo pipefail

LOOP_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TEMPLATE="$LOOP_DIR/loop.env.dist"

GLOBAL_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/engineering-loop/loop.env"
REPO_FILE=""
if common="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  REPO_FILE="$(cd "$common" && pwd -P)/engineering-loop/loop.env"
fi

# ---------------------------------------------------------------------------- the files

# Rewrite one key in place. awk rather than sed: a token can contain characters sed would treat as
# delimiters, and a mangled credential fails somewhere far away from here.
put() {
  local file="$1" key="$2" val="$3"
  awk -v k="$key" -v v="$val" -F= '
    $1 == k { printf "%s=%s\n", k, v; found = 1; next }
    { print }
    END { if (!found) printf "%s=%s\n", k, v }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  chmod 600 "$file"
}

current() { awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2) }' "$1" 2>/dev/null | head -1; }

# Created from the template on first use, whichever mode gets there first.
ensure_file() {
  local file="$1"
  [ -f "$TEMPLATE" ] || { echo "initialize: $TEMPLATE is missing" >&2; exit 3; }
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || cp "$TEMPLATE" "$file"
  chmod 600 "$file"
}

# Names and whether each has a value -- never the value.
show_file() {
  local label="$1" file="$2"
  if [ -z "$file" ]; then
    printf '%-8s (not inside a repository)\n' "$label"
  elif [ ! -f "$file" ]; then
    printf '%-8s %s: absent\n' "$label" "$file"
  else
    printf '%-8s %s:\n' "$label" "$file"
    awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {
      printf "  %-28s %s\n", $1, (length($2) > 0 ? "set" : "EMPTY")
    }' "$file"
  fi
}

# The mode the loop will run with, and where it comes from: the repository's file first, then the
# global one -- the same order the loop reads them in.
effective_sandbox() {
  local v
  if [ -n "${LOOP_ENV:-}" ]; then
    v="$(current "$LOOP_ENV" LOOP_SANDBOX)"
    [ -n "$v" ] && { echo "$v ($LOOP_ENV)"; return 0; }
  else
    v="$(current "$REPO_FILE" LOOP_SANDBOX)"
    [ -n "$v" ] && { echo "$v (repo)"; return 0; }
    v="$(current "$GLOBAL_FILE" LOOP_SANDBOX)"
    [ -n "$v" ] && { echo "$v (global)"; return 0; }
  fi
  echo "unset"
}

show() {
  if [ -n "${LOOP_ENV:-}" ]; then
    show_file "LOOP_ENV" "$LOOP_ENV"
  else
    show_file "global" "$GLOBAL_FILE"
    show_file "repo" "$REPO_FILE"
  fi
  echo "effective LOOP_SANDBOX: $(effective_sandbox)"
}

# ---------------------------------------------------------------------------- arguments

MODE="setup"
SCOPE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --show)   MODE="show" ;;
    --host)   MODE="host" ;;
    --repo)   SCOPE="repo" ;;
    --global) SCOPE="global" ;;
    *) echo "usage: initialize.sh [--show | --host (--repo | --global)]" >&2; exit 2 ;;
  esac
  shift
done

# The file a scope names. LOOP_ENV, when set, is the only file there is.
file_for_scope() {
  if [ -n "${LOOP_ENV:-}" ]; then
    printf '%s' "$LOOP_ENV"
    return 0
  fi
  case "$1" in
    repo)
      if [ -z "$REPO_FILE" ]; then
        echo "initialize: --repo needs to run inside the repository it is for; this directory is not in one." >&2
        exit 3
      fi
      printf '%s' "$REPO_FILE" ;;
    global) printf '%s' "$GLOBAL_FILE" ;;
  esac
}

case "$MODE" in
  show)
    show
    exit 0
    ;;
  host)
    if [ -z "$SCOPE" ] && [ -z "${LOOP_ENV:-}" ]; then
      echo "initialize: --host needs a scope: --repo (this repository) or --global (every repository)." >&2
      exit 2
    fi
    FILE="$(file_for_scope "${SCOPE:-global}")"
    ensure_file "$FILE"
    put "$FILE" LOOP_SANDBOX 0
    echo "LOOP_SANDBOX=0 written to $FILE: sessions run on this host, as you, with your ssh keys, gh"
    echo "login and the Claude account the shell is logged into. Run $LOOP_DIR/initialize.sh to switch to a"
    echo "container later."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------- interactive setup

if [ ! -t 0 ]; then
  echo "initialize: this asks questions, so it needs a real terminal (a Claude Code '!' command is not one)." >&2
  echo "Run it from a terminal. To run sessions on this host without questions:" >&2
  echo "  $LOOP_DIR/initialize.sh --host --repo      (this repository)" >&2
  echo "  $LOOP_DIR/initialize.sh --host --global    (every repository)" >&2
  echo "Or copy $TEMPLATE to $GLOBAL_FILE and fill it in by hand." >&2
  exit 3
fi

# `read -s` so a token never lands in the terminal scrollback or the shell history. `|| true`
# because read returns non-zero at EOF, and `set -e` would otherwise abandon the run.
ask_secret() {
  local file="$1" key="$2" prompt="$3" existing value
  existing="$(current "$file" "$key")"
  if [ -n "$existing" ]; then
    printf '  %s is already set here. Press ENTER to keep it, or paste a new one: ' "$key"
  else
    printf '  %s' "$prompt"
  fi
  read -r -s value || true
  echo
  [ -n "$value" ] && put "$file" "$key" "$value"
  return 0
}

cat <<'INTRO'

Engineering-loop setup
======================

The loop builds a spec unattended: one fresh session per phase, then a review, then
a PR. Nobody watches those sessions, so where they run matters. This asks two
questions, then, for a container, the two tokens it needs. Nothing you type is
echoed, and every file is written 0600.

INTRO

cat <<'Q1'
1/2  Run the sessions in a container?

     Container (recommended)
       Each session sees this repository's worktree and two tokens minted for it,
       and nothing else on this machine: no ~/.ssh, no other repositories, no gh
       login, and no Claude login but the token, which also decides which Claude
       account the run bills. A confused session cannot reach what it cannot see.
       Costs: Docker, two tokens minted once a year, and an image built once.

     This host
       Each session runs as you: your ssh keys, your gh login, and whichever Claude
       account this shell is logged into. No setup, and no wall between a mistake
       and everything you can reach.

Q1
printf '     Container? [Y/n] '
read -r answer || true
case "${answer:-}" in
  [Nn]*) SANDBOX=0 ;;
  *)     SANDBOX=1 ;;
esac

if [ -n "${LOOP_ENV:-}" ]; then
  FILE="$LOOP_ENV"
  echo
  echo "     Writing to $FILE (LOOP_ENV)."
else
  cat <<'Q2'

2/2  For every repository, or for this one?

     Global    ~/.config/engineering-loop/loop.env -- your default. One account,
               one mode, every repository you build in.
     This repo <repository>/.git/engineering-loop/loop.env -- what differs here:
               another account, another mode. Inside .git/, so it can never be
               committed, and shared by every worktree of the repository. It wins
               over the global file, key by key.

Q2
  if [ -n "$REPO_FILE" ]; then
    printf '     [G]lobal or [t]his repository? [G/t] '
    read -r scope || true
    case "${scope:-}" in
      [Tt]*) FILE="$REPO_FILE" ;;
      *)     FILE="$GLOBAL_FILE" ;;
    esac
  else
    echo "     Not inside a repository, so: global."
    FILE="$GLOBAL_FILE"
  fi
fi

ensure_file "$FILE"
put "$FILE" LOOP_SANDBOX "$SANDBOX"

if [ "$SANDBOX" = 1 ]; then
  cat <<'CLAUDE_HELP'

     The container inherits no login, so it needs two tokens of its own.

     CLAUDE_CODE_OAUTH_TOKEN
       Authenticates the session against a Claude subscription, and decides which
       account the run bills. Mint it under the account you want:
         claude setup-token
       (with CLAUDE_CONFIG_DIR pointing at that account's config, if you use more
       than one). It lasts about a year.

CLAUDE_HELP
  ask_secret "$FILE" CLAUDE_CODE_OAUTH_TOKEN "paste the token (input hidden): "

  cat <<'GH_HELP'

     GH_TOKEN
       Lets the unit push its branch and open its PR. Use a FINE-GRAINED personal
       access token from the GitHub account that owns the repository:
         github.com -> Settings -> Developer settings -> Fine-grained tokens
         Repository access: only this repository
         Permissions: Contents = Read and write, Pull requests = Read and write
       A scoped token is what makes "the loop never merges" a property of what it
       holds rather than a rule it could route around. `gh auth token` also works,
       but hands the container your whole account, merging included.

GH_HELP
  ask_secret "$FILE" GH_TOKEN "paste the token (input hidden): "

  IMAGE="${LOOP_IMAGE:-engineering-loop:local}"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo
    if command -v docker >/dev/null 2>&1; then
      printf '     The sandbox image %s is not built yet. Build it now? [Y/n] ' "$IMAGE"
      read -r build || true
      case "${build:-}" in
        [Nn]*) echo "     Build it before the first run:  $LOOP_DIR/sandbox/build.sh" ;;
        *)     "$LOOP_DIR/sandbox/build.sh" ;;
      esac
    else
      echo "     Docker is not on PATH. Install it, then build the image once:  $LOOP_DIR/sandbox/build.sh"
    fi
  fi
else
  echo
  echo "     LOOP_SANDBOX=0: sessions run on this host, as you."
fi

echo
echo "Written to $FILE (0600)."
echo
show
echo
echo "Next, in Claude Code, inside a repository:  /ship <what you want>"
