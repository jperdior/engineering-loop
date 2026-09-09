#!/bin/sh
#
# Install the engineering loop into Claude Code and run its setup, in one go:
#
#   curl -fsSL https://raw.githubusercontent.com/jperdior/engineering-loop/main/install.sh | sh
#
# It adds this repository as a plugin marketplace, installs the plugin at user scope, then runs the
# plugin's initialize.sh in the terminal you are in: where the loop's sessions run, for every
# repository or this one, and the two tokens a container needs. Run it from inside a repository to
# be offered the per-repository scope.
#
# This is the one piece that knows it is talking to Claude Code; the skills and the loop do not.
# Support for another agent is a second branch of this file, not a change to them.
#
# ENGINEERING_LOOP_MARKETPLACE overrides the marketplace source (default: jperdior/engineering-loop).
#
# Exit: 0 installed and set up, 3 the claude CLI or the installed plugin could not be found.

set -eu

MARKETPLACE="${ENGINEERING_LOOP_MARKETPLACE:-jperdior/engineering-loop}"

if ! command -v claude >/dev/null 2>&1; then
  echo "install: the claude CLI is not on PATH. Install Claude Code first, then re-run this." >&2
  exit 3
fi

echo "install: adding the marketplace $MARKETPLACE"
# Already added is not a failure; a real failure surfaces at the install step below.
claude plugin marketplace add "$MARKETPLACE" >/dev/null 2>&1 || true

echo "install: installing engineering-loop"
claude plugin install -y engineering-loop@engineering-loop

# The plugin's files live in the CLI's cache, under the config dir the CLI uses. Newest version wins.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INIT=""
for dir in "$CONFIG_DIR"/plugins/cache/engineering-loop/engineering-loop/*/; do
  [ -x "$dir/loop/initialize.sh" ] || continue
  if [ -z "$INIT" ] || [ "$dir/loop/initialize.sh" -nt "$INIT" ]; then
    INIT="$dir/loop/initialize.sh"
  fi
done
if [ -z "$INIT" ]; then
  echo "install: the plugin is installed but initialize.sh was not found under $CONFIG_DIR/plugins/cache." >&2
  echo "install: in Claude Code, run /plugin list to see where it went, then run <plugin>/loop/initialize.sh." >&2
  exit 3
fi

echo "install: installed. Setting up."
echo
# Under `curl | sh` stdin is the pipe, so the questions are read from the terminal itself.
if [ -r /dev/tty ]; then
  "$INIT" </dev/tty
else
  echo "install: no terminal to ask questions on. Run the setup yourself:" >&2
  echo "  $INIT" >&2
  exit 3
fi
