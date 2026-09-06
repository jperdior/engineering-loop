#!/usr/bin/env bash
#
# Walk a human through the two credentials the sandboxed loop needs, and write them to the user's
# settings file: ~/.config/engineering-loop/loop.env (LOOP_ENV overrides the path). The file is the
# user's and serves every repository; nothing is written into any repository.
#
# Both tokens are minted through a browser, so a script cannot fetch them. What it can do is explain
# each one when it is asked for, write the values with the right file mode, and never echo them back.
#
# Idempotent. Run it again to change one value and keep the rest.
#
# Usage: setup-loop.sh [--show]   --show prints what is configured, never the secrets.
#
# Exit: 0 written, 2 usage, 3 refused.

set -euo pipefail

MODE="${1:-setup}"

LOOP_DIR="$(cd "$(dirname "$0")" && pwd -P)"

ENV_FILE="${LOOP_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/engineering-loop/loop.env}"
TEMPLATE="$LOOP_DIR/loop.env.dist"

case "$MODE" in
  setup|--setup) ;;
  --show)
    if [ ! -f "$ENV_FILE" ]; then
      echo "Not configured ($ENV_FILE is absent). Run: $LOOP_DIR/setup-loop.sh"
      exit 0
    fi
    echo "Configured in $ENV_FILE:"
    # Names and whether each has a value -- never the value.
    awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {
      printf "  %-28s %s\n", $1, (length($2) > 0 ? "set" : "EMPTY")
    }' "$ENV_FILE"
    exit 0
    ;;
  *) echo "usage: setup-loop.sh [--show]" >&2; exit 2 ;;
esac

if [ ! -t 0 ]; then
  echo "setup-loop: this asks questions, so it needs a real terminal (a Claude Code '!' command is not one)." >&2
  echo "Run it from a terminal, or copy $TEMPLATE to $ENV_FILE and set its GH_TOKEN= and CLAUDE_CODE_OAUTH_TOKEN= lines by hand." >&2
  exit 3
fi

[ -f "$TEMPLATE" ] || { echo "setup-loop: $TEMPLATE is missing" >&2; exit 3; }
mkdir -p "$(dirname "$ENV_FILE")"
[ -f "$ENV_FILE" ] || cp "$TEMPLATE" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Read the value already stored, so a re-run can offer to keep it.
current() { awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2) }' "$ENV_FILE" | head -1; }

# Rewrite one key in place. A here-doc rather than sed: a token can contain characters sed would
# treat as delimiters, and a mangled credential fails somewhere far away from here.
put() {
  local key="$1" val="$2"
  awk -v k="$key" -v v="$val" -F= '
    $1 == k { printf "%s=%s\n", k, v; found = 1; next }
    { print }
    END { if (!found) printf "%s=%s\n", k, v }
  ' "$ENV_FILE" > "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

# `read -s` so a token never lands in the terminal scrollback or the shell history.
ask_secret() {
  local key="$1" prompt="$2" existing value
  existing="$(current "$key")"
  if [ -n "$existing" ]; then
    printf '  %s is already set. Press ENTER to keep it, or paste a new one: ' "$key"
  else
    printf '  %s' "$prompt"
  fi
  # `|| true` because read returns non-zero at EOF, and `set -e` would otherwise abandon the run --
  # losing everything answered so far to a stray Ctrl-D.
  read -r -s value || true
  echo
  [ -n "$value" ] && put "$key" "$value"
  return 0
}

cat <<'INTRO'

Engineering-loop setup
======================

The loop builds a spec's units unattended, one PR at a time. When it runs inside
a container (LOOP_SANDBOX=1) that container inherits none of your logins, so it
needs two tokens of its own. Both are minted in a browser, and both last about a
year -- this is a once-a-year job, not a per-run one.

Nothing you type here is echoed, and the file is written 0600.

INTRO

cat <<'CLAUDE_HELP'
1/2  CLAUDE_CODE_OAUTH_TOKEN
     Authenticates the session against YOUR Claude subscription. On macOS your
     own login lives in the Keychain, so there is nothing a container can mount
     -- hence a token.

     Get it with:   claude setup-token

CLAUDE_HELP
ask_secret CLAUDE_CODE_OAUTH_TOKEN "paste the token (input hidden): "

cat <<'GH_HELP'

2/2  GH_TOKEN
     Lets the unit push its branch and open its PR.

     STRONGLY PREFERRED -- a fine-grained PAT limited to this repository:
       github.com -> Settings -> Developer settings -> Fine-grained tokens
       Repository access: only this repository
       Permissions: Contents = Read and write, Pull requests = Read and write

     `gh auth token` also works and needs no setup, but it hands the container
     your FULL user token: every repository you own, and the ability to merge.
     The scoped one is what makes "the loop never merges into production" a
     property of what it holds rather than a rule it could route around.

     It goes here rather than in ~/.zshrc because GH_TOKEN overrides
     `gh auth switch` -- a global one silently hijacks every interactive gh
     command in a repository worked with two accounts.

GH_HELP
ask_secret GH_TOKEN "paste the token (input hidden): "

printf '\n3/3  Run the unit in a container? [Y/n] '
read -r sandbox || true
case "${sandbox:-}" in
  [Nn]*) put LOOP_SANDBOX 0
         echo "     LOOP_SANDBOX=0 -- sessions run on this host, with your ssh keys and gh login." ;;
  *)     put LOOP_SANDBOX 1
         echo "     LOOP_SANDBOX=1 -- build the image once with:  $LOOP_DIR/sandbox/build.sh" ;;
esac

echo
echo "Written to $ENV_FILE (0600, outside every repository)."
"$LOOP_DIR/setup-loop.sh" --show
echo
echo "Next, in Claude Code:  /ship <what you want>"
