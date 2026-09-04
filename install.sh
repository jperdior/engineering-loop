#!/usr/bin/env bash
#
# Install (or update) the engineering loop into a host repository.
#
# What it puts in the host:
#
#   .loop/                     the engine, vendored: the scripts, the sandbox Dockerfile, the skills,
#                              and loop.env.dist. Re-running install replaces it; loop.env and state/
#                              are left alone.
#   .claude/skills/<name>      a symlink per skill into .loop/skills/<name>, so Claude Code finds them.
#   .ai/specs/                 created empty if absent; specs live here.
#   .gitignore                 gains .loop/loop.env, .loop/state/, .claude/worktrees/ and
#                              .claude/settings.local.json if they are not already ignored.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jperdior/engineering-loop/main/install.sh | bash
#   bash install.sh [<host-repo-path>]      -- from a clone of this repository
#
# ENGINEERING_LOOP_REF pins the ref to install (default: main).
#
# Exit: 0 installed, 2 usage, 3 the target is not a git repository.

set -euo pipefail

TARGET="${1:-.}"
REF="${ENGINEERING_LOOP_REF:-main}"
SOURCE="https://github.com/jperdior/engineering-loop"

if ! git -C "$TARGET" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "install: $TARGET is not inside a git repository" >&2
  exit 3
fi
HOST="$(git -C "$TARGET" rev-parse --show-toplevel)"

# From a clone, install from it; from `curl | bash`, fetch the ref into a temp dir.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)"
if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/loop/delivery-loop.sh" ]; then
  SRC="$SELF_DIR"
else
  SRC="$(mktemp -d -t engineering-loop.XXXXXX)"
  trap 'rm -rf "$SRC"' EXIT
  git clone --quiet --depth 1 --branch "$REF" "$SOURCE" "$SRC"
fi

echo "install: engineering loop -> $HOST/.loop"

mkdir -p "$HOST/.loop/skills" "$HOST/.claude/skills" "$HOST/.ai/specs"

# The engine is replaced whole; the host's own settings and state are not touched.
for f in delivery-loop.sh parse-ledger.sh unit-size.sh comment-ratio.sh reclaim-worktree.sh setup-loop.sh loop.env.dist; do
  cp "$SRC/loop/$f" "$HOST/.loop/$f"
done
mkdir -p "$HOST/.loop/sandbox"
cp "$SRC/loop/sandbox/Dockerfile" "$SRC/loop/sandbox/build.sh" "$HOST/.loop/sandbox/"
chmod +x "$HOST/.loop/"*.sh "$HOST/.loop/sandbox/build.sh"

for skill in "$SRC"/skills/*/; do
  name="$(basename "$skill")"
  rm -rf "$HOST/.loop/skills/$name"
  cp -R "$skill" "$HOST/.loop/skills/$name"
  # A symlink, so an update to .loop/ is an update to the skill Claude Code loads.
  if [ -e "$HOST/.claude/skills/$name" ] && [ ! -L "$HOST/.claude/skills/$name" ]; then
    echo "install: .claude/skills/$name exists and is not a symlink; leaving it. Remove it to use the engine's." >&2
  else
    ln -sfn "../../.loop/skills/$name" "$HOST/.claude/skills/$name"
  fi
done

# Ignored paths, appended once.
touch "$HOST/.gitignore"
for line in ".loop/loop.env" ".loop/state/" ".claude/worktrees/" ".claude/settings.local.json"; do
  grep -qxF "$line" "$HOST/.gitignore" || echo "$line" >> "$HOST/.gitignore"
done

cat <<NEXT

Installed. Next:

  1. Set the host contract in .loop/loop.env (start from .loop/loop.env.dist):
       LOOP_GATES=<the commands that must be green, separated by ;>    e.g. make lint;make test
  2. Optional, for unattended runs in a container:  .loop/setup-loop.sh  then  .loop/sandbox/build.sh
  3. Install the superpowers plugin in Claude Code (the skills use its brainstorming, TDD and
     subagent-driven-development skills).
  4. In Claude Code:  /ship <what you want>

Commit .loop/, .claude/skills/ and .gitignore.
NEXT
