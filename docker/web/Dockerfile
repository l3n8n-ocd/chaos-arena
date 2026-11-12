# syntax=docker/dockerfile:1
# =============================================================================
# Dockerfile for the Chaos Arena "web" container (Module 04)
#
# Nginx inside a container: serves the game's web page and forwards /api/
# requests to the "app" container over Docker's private network.
#
# Build context is the REPO ROOT (it needs app/public and docker/web);
# Dockerfile.dockerignore next to this file keeps everything else out.
#
# Build:  docker build -f docker/web/Dockerfile -t chaos-arena-web .
# =============================================================================

# "unprivileged" variant: Nginx runs as a normal user (uid 101) on port 8080,
# instead of as root on port 80.
ARG NGINX_IMAGE=public.ecr.aws/nginx/nginx-unprivileged:1.28-alpine
FROM ${NGINX_IMAGE}

LABEL org.opencontainers.image.title="chaos-arena-web" \
      org.opencontainers.image.description="Chaos Arena web page + reverse proxy to the game API" \
      org.opencontainers.image.source="https://github.com/l3n8n-ocd/chaos-arena"

# Our site config replaces the default one.
COPY docker/web/nginx.conf /etc/nginx/conf.d/default.conf
# The game's web page (HTML, CSS, JavaScript) is baked into the image.
COPY app/public /usr/share/nginx/html

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1
