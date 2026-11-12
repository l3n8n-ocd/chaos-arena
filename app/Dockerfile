# syntax=docker/dockerfile:1
# =============================================================================
# Dockerfile for the Chaos Arena game server (Module 04)
#
# Multi-stage build: each "FROM" starts a new stage. Only the last stage
# becomes the final image, so build tools and test files never ship.
#
#   deps     -> installs production dependencies only
#   test     -> installs everything and runs the tests (optional: --target test)
#   runtime  -> the small final image that actually runs
#
# Build:  docker build -t chaos-arena-app ./app
# Test:   docker build --target test ./app
# =============================================================================

# The base image comes from AWS's public registry (a copy of the official
# Docker Hub image), which avoids Docker Hub download limits on EC2.
ARG NODE_IMAGE=public.ecr.aws/docker/library/node:22-alpine

# ---------------------------------------------------------------------------
# Stage 1: production dependencies
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
# Copy ONLY the package files first. Docker caches each step ("layer"), so as
# long as these two files don't change, the slow "npm ci" step is reused from
# cache even when the source code changes.
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-audit --no-fund

# ---------------------------------------------------------------------------
# Stage 2: tests (only built when asked for: --target test)
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS test
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund
COPY . .
RUN npm test

# ---------------------------------------------------------------------------
# Stage 3: runtime (the final image)
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

LABEL org.opencontainers.image.title="chaos-arena-app" \
      org.opencontainers.image.description="Chaos Arena game server: a tug-of-war you're allowed to crash" \
      org.opencontainers.image.source="https://github.com/l3n8n-ocd/chaos-arena"

# Defaults; docker-compose / docker run can override any of them.
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000

WORKDIR /app

# Files are owned by root and only READ by the app. If the app were ever
# hacked, it could not change its own code.
COPY --from=deps /app/node_modules ./node_modules
COPY package.json server.js ./
COPY src ./src
COPY public ./public

# /data is where STORE=file keeps the game (mounted as a volume).
RUN mkdir -p /data && chown node:node /data

# Never run as root: the official Node image includes a "node" user.
USER node

EXPOSE 3000

# Docker asks the app "are you healthy?" every 10 s. Node 22 has fetch()
# built in, so no extra tools (like curl) are needed in the image.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

CMD ["node", "server.js"]
