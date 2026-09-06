#!/usr/bin/env bash
#
# Build the image the delivery loop runs `claude -p` inside when LOOP_SANDBOX=1.
#
# `--load` rather than the default: with a containerd image store the build produces a manifest
# list, which `docker images` lists at full size and `docker image inspect <tag>` cannot resolve --
# and the loop's pre-flight asks inspect, because that is the call that says whether the image can be
# RUN. Loading it as a single image is what makes the tag resolvable.
#
# Usage: sandbox/build.sh (from the plugin's loop/)   -- builds ${LOOP_IMAGE:-engineering-loop:local}

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
IMAGE="${LOOP_IMAGE:-engineering-loop:local}"

docker build --load -t "$IMAGE" -f "$HERE/Dockerfile" "$HERE"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "build.sh: built, but 'docker image inspect' cannot resolve $IMAGE by tag." >&2
  exit 1
fi

echo "Built $IMAGE. It carries no credentials: the loop passes CLAUDE_CODE_OAUTH_TOKEN and GH_TOKEN"
echo "from ~/.config/engineering-loop/loop.env at run time."
