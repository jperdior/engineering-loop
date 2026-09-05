# The image the delivery loop runs `claude -p` inside when LOOP_SANDBOX=1.
#
# What it bounds: lateral reach. The container has no ~/.ssh, no ~/.aws, no other repositories, and
# no gh credential beyond the repo-scoped token the loop passes in. What it does not bound: a host
# whose gates run docker gets the host socket, and a container holding that socket is not isolated
# from a determined escape. It stops accidents, which is the threat an unattended loop presents.
#
# The credential is the real boundary. A fine-grained PAT limited to one repository makes "the loop
# never merges" a property of what it holds; the deny list in delivery-loop.sh is a second line.
FROM node:22-bookworm-slim

# git for the worktree, jq because the skills read JSON, make and bash because most hosts' gates are
# make targets.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq make bash procps \
    && rm -rf /var/lib/apt/lists/*

# The Docker CLI only, no daemon: it talks to the host socket mounted at runtime. buildx is needed
# because a gate running `docker compose up --build` on a Dockerfile with `RUN --mount=type=cache`
# requires BuildKit, and without the plugin it dies naming neither buildx nor the compose file.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
       docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# gh, for /open-pr. It authenticates from GH_TOKEN.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli.gpg \
    && chmod a+r /etc/apt/keyrings/githubcli.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# The loop runs the container as the invoking uid, which owns no home directory inside it, so the
# CLI's config dir is a world-writable path instead.
ENV CLAUDE_CONFIG_DIR=/loop-config
RUN mkdir -p /loop-config && chmod 0777 /loop-config

ENTRYPOINT ["claude"]
