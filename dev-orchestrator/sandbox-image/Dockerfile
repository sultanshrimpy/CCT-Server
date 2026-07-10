FROM node:22-bookworm-slim

# git — needed at runtime for `git submodule` status checks some tooling does,
# and generally useful if you shell into a running sandbox to poke around.
# python3/make/g++ — some transitive deps (e.g. better-sqlite3-likes) need a
# native build step.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5173
ENTRYPOINT ["/entrypoint.sh"]

