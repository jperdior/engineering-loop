# The image the delivery loop runs `claude -p` inside.
#
# WHAT THIS BOUNDS, AND WHAT IT DOES NOT. A host whose gates run `docker compose` needs Docker
# inside this container, and it gets it through the host socket. A container holding the host socket
# can start `docker run -v /:/host` and is therefore NOT isolated from a determined escape. What it
# does isolate is everything a confused agent can reach by accident, which is the threat an unattended
# loop actually presents: no `~/.ssh`, so `ssh root@prod` cannot resolve a key; no `~/.aws`, no
# `.env.local` outside the unit's own worktree, no other repositories on the disk, and no `gh`
# credential beyond a repo-scoped token. `rm -rf ~/devel` reaches nothing.
#
# The credential is the real boundary. A fine-grained PAT limited to this repository turns
# "the loop never merges into production" from a rule the agent could route around into a property of
# what it holds. The blocklist in delivery-loop.sh stays as a second line, not the only one.
FROM node:22-bookworm-slim

# git and openssh-client for git over https; ca-certificates for both API endpoints; jq because the
# loop's own prompt and the skills read JSON. `make` and `bash` because most hosts' gates are make targets.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq make bash procps \
    && rm -rf /var/lib/apt/lists/*

# The Docker CLI only -- no daemon. It talks to the host socket mounted at runtime. Installing the
# whole engine here would be dead weight: nothing in this container runs containers of its own.
#
# buildx is NOT optional even though nothing in this container builds an image for its own sake: a
# host gate that runs `docker compose up --build` on a Dockerfile using `RUN --mount=type=cache`
# needs BuildKit, which is buildx. Without the plugin the gate dies on "the --mount option requires
# BuildKit", naming neither buildx nor the compose file.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
       docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# gh, for `/open-pr` and for reading a PR's comments and checks. It authenticates from GH_TOKEN.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli.gpg \
    && chmod a+r /etc/apt/keyrings/githubcli.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# The loop runs as the invoking user's uid so files it writes in the mounted worktree are owned by
# them, not by root. Compose passes it at runtime; this is only the fallback.
ENV CLAUDE_CONFIG_DIR=/loop-config
RUN mkdir -p /loop-config && chmod 0777 /loop-config

ENTRYPOINT ["claude"]
