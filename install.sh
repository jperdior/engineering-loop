#!/usr/bin/env bash
#
# Install (or update) the engineering loop into a host repository.
#
# What it puts in the host:
#
#   .loop/                     the engine, vendored: the scripts, the sandbox Dockerfile, the skills,
#                              loop.env.dist and host.env.dist. Re-running install replaces it;
#                              host.env (the host's committed contract), loop.env and state/ are
#                              left alone.
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

# The engine is replaced whole; the host's own host.env, loop.env and state/ are not touched.
cp "$SRC"/loop/*.sh "$SRC/loop/loop.env.dist" "$SRC/loop/host.env.dist" "$HOST/.loop/"
mkdir -p "$HOST/.loop/sandbox"
cp "$SRC/loop/sandbox/Dockerfile" "$SRC/loop/sandbox/build.sh" "$HOST/.loop/sandbox/"
chmod +x "$HOST/.loop/"*.sh "$HOST/.loop/sandbox/build.sh"

# When the skills come from the engineering-loop plugin, the symlinks would only duplicate them.
SKILLS_VIA_PLUGIN=0
if command -v claude >/dev/null 2>&1 && claude plugin list 2>/dev/null | grep -q 'engineering-loop@'; then
  SKILLS_VIA_PLUGIN=1
  echo "install: the engineering-loop plugin is installed; not symlinking the skills into .claude/skills/"
fi

for skill in "$SRC"/skills/*/; do
  name="$(basename "$skill")"
  rm -rf "$HOST/.loop/skills/$name"
  cp -R "$skill" "$HOST/.loop/skills/$name"
  # A symlink, so an update to .loop/ is an update to the skill Claude Code loads.
  if [ "$SKILLS_VIA_PLUGIN" = 1 ]; then
    :
  elif [ -e "$HOST/.claude/skills/$name" ] && [ ! -L "$HOST/.claude/skills/$name" ]; then
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

# The skills depend on the superpowers plugin (brainstorming, test-driven-development,
# subagent-driven-development, dispatching-parallel-agents). Install it at user scope when the
# claude CLI is here and it is not already present; a failure is reported, not fatal.
superpowers_note="already installed"
if ! command -v claude >/dev/null 2>&1; then
  superpowers_note="the claude CLI is not on PATH; in Claude Code run: /plugin install superpowers@claude-plugins-official"
elif ! claude plugin list 2>/dev/null | grep -q 'superpowers@'; then
  if claude plugin install -y superpowers@claude-plugins-official >/dev/null 2>&1; then
    superpowers_note="installed at user scope"
  else
    superpowers_note="could not be installed automatically; in Claude Code run:
       /plugin install superpowers@claude-plugins-official"
  fi
fi

cat <<NEXT

Installed. superpowers plugin: $superpowers_note

Next:

  1. The host contract, .loop/host.env (committed): /ship writes it from your AGENTS.md on its first
     run and shows you the lines. Or write it by hand from .loop/host.env.dist, at least:
       LOOP_GATES=<the commands that must be green, separated by ;>    e.g. make lint;make test
  2. Optional, for unattended runs in a container:  .loop/setup-loop.sh  then  .loop/sandbox/build.sh
  3. In Claude Code:  /ship <what you want>

Commit .loop/ (host.env included), .claude/skills/ and .gitignore.
NEXT
