#!/usr/bin/env bash
#
# Every skill's frontmatter must parse as YAML and carry a name and a description.
#
# Run: bash tests/test-skills-frontmatter.sh
#
# Claude Code drops a skill whose frontmatter does not parse from its slash-command index and says
# nothing. An unquoted description containing `: ` is a YAML error, and one containing ` #` is
# silently truncated at the hash; both have happened here. Descriptions are therefore double-quoted,
# and this suite parses each one the way a strict reader does. Ruby ships with macOS and the CI
# runner; the suite skips, loudly, where it is absent rather than passing vacuously.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v ruby >/dev/null 2>&1; then
  echo "test-skills-frontmatter: ruby is not on PATH; nothing was checked" >&2
  exit 3
fi

failures=0
for skill in skills/*/SKILL.md; do
  name="$(basename "$(dirname "$skill")")"
  fm="$(sed -n '2,/^---$/p' "$skill" | sed '$d')"
  # The program is Ruby, not shell; nothing in it is meant to expand here.
  # shellcheck disable=SC2016
  if verdict="$(ruby -ryaml -e '
      d = YAML.safe_load(STDIN.read)
      abort "frontmatter is not a mapping" unless d.is_a?(Hash)
      abort "name is #{d["name"].inspect}, expected #{ARGV[0].inspect}" unless d["name"] == ARGV[0]
      abort "description is missing or too short" unless d["description"].to_s.length > 40
      abort "description must be double-quoted (a bare `: ` or ` #` breaks the loader)" unless File.read(ARGV[1]) =~ /^description: "/
      puts "ok"
    ' "$name" "$skill" <<<"$fm" 2>&1)"; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %-24s %s\n' "$name" "$verdict" >&2
    failures=$((failures + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  printf '\nFAIL: %d skill(s) have unloadable frontmatter.\n' "$failures" >&2
  exit 1
fi
printf '\nOK -- skills frontmatter\n'
