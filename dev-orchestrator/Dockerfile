FROM node:20-bookworm-slim

# git — for worktree management
# docker CLI + compose plugin — this container talks to the host Docker
# daemon via the bind-mounted /var/run/docker.sock, it needs the client
# binaries to do so (this does NOT install/run a nested Docker daemon)
# python3/make/g++ — needed to compile node-pty's native bindings (used for
# the in-browser terminal feature)
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl gnupg python3 make g++ \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src

EXPOSE 8700
CMD ["node", "src/server.js"]

