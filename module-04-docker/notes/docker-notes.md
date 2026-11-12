# Docker Notes — Module 04

## Containers vs virtual machines

| | Virtual machine (my EC2 instance) | Container (my app) |
|---|---|---|
| What it virtualizes | A whole computer: hardware, kernel, OS | Just a process, with its own view of files, network, users |
| Kernel | Its own | **Shares the host's Linux kernel** |
| Size | GBs | MBs (my app image: ~270 MB, web: ~80 MB) |
| Start time | Tens of seconds to minutes | Under a second |
| Isolation | Strong (hypervisor) | Good (namespaces + cgroups), weaker than a VM |
| Typical use | Run an OS | Run one app the same way everywhere |

They're used **together**: my EC2 VM runs Docker, and Docker runs my containers.

How the isolation works:
- **Namespaces** give each container its own view: process list (PID), network (its own IP), filesystem (mount), hostname, users.
- **cgroups** limit what it may use: my `memory: 300M`, `cpus: 0.60`, `pids: 100`.

## Docker architecture

```
 docker CLI ──REST API──> dockerd (Docker daemon) ──> containerd ──> runc ──> container process
 (what I type)              builds images,             manages          creates the
                            networks, volumes          container        namespaces/cgroups
                                   │                   lifecycles
                                   └── pulls/pushes images ──> Registry (Docker Hub, AWS ECR Public, GHCR)
```

| Term | Meaning |
|---|---|
| **Image** | Read-only template: a stack of filesystem **layers** + metadata (CMD, USER, ENV...) |
| **Container** | A running (or stopped) instance of an image, plus a thin writable layer |
| **Registry** | Where images are stored and shared (`public.ecr.aws`, `docker.io`, `ghcr.io`) |
| **Tag** | A name for an image version: `node:22-alpine`, `chaos-arena-app:local` |
| **Dockerfile** | The recipe that builds an image |
| **Compose** | A YAML file describing several containers that work together |

## Images and layers
- Each Dockerfile instruction that changes files (`COPY`, `RUN`) creates a **layer**. Layers are cached and shared.
- If a layer changes, every layer **after** it is rebuilt. So put rarely-changing steps first.
- `docker history <image>` shows the layers and their sizes.

## Dockerfile optimization: what I did and why

| Technique | In my `app/Dockerfile` | Why |
|---|---|---|
| **Multi-stage build** | `deps` → `test` → `runtime` stages | Only the final stage ships; tests and dev tools never reach production |
| **Cache-friendly order** | `COPY package*.json` → `npm ci` → *then* `COPY src` | Changing code doesn't re-download dependencies |
| **Production deps only** | `npm ci --omit=dev` | Smaller image, fewer packages to attack |
| **Small base image** | `node:22-alpine` | ~50 MB base vs ~400 MB for the full Debian image |
| **`.dockerignore`** | Excludes `node_modules`, `.env`, `.data` | Faster builds; secrets can't leak into an image |
| **Build cache mount** | `RUN --mount=type=cache,target=/root/.npm` | Re-builds reuse downloaded packages |
| **Non-root user** | `USER node` | A hacked app isn't root inside the container |
| **Read-only code** | Files owned by root, app runs as `node` | The app can't modify itself |
| **Exec-form CMD** | `CMD ["node", "server.js"]` | Signals go straight to Node, not to a shell |
| **HEALTHCHECK** | `fetch('/api/health')` every 10 s | Docker knows if the app works, not just if it runs |
| **Pinned major version** | `node:22-alpine`, `nginx-unprivileged:1.28-alpine` | Predictable builds (pin a digest for full reproducibility) |
| **Registry choice** | `public.ecr.aws/...` | Same official images, no Docker Hub download limits on AWS |

## Docker commands I used

| Command | What it does |
|---|---|
| `docker build -t name ./dir` | Build an image from a Dockerfile |
| `docker image ls` / `docker history img` | List images / show an image's layers |
| `docker run --rm -it img sh` | Start a throw-away container with a shell |
| `docker ps -a` | List containers (incl. stopped) |
| `docker logs -f ctr` | Follow a container's output |
| `docker exec -it ctr sh` | Open a shell in a running container |
| `docker inspect ctr` | Everything about a container (JSON) |
| `docker stats` | Live CPU/memory per container |
| `docker events` | Live stream of what Docker is doing (start, die, health...) |
| `docker network ls` / `inspect` | Networks and who's on them |
| `docker volume ls` / `inspect` | Volumes and where they live |
| `docker system df` / `docker builder prune` | Disk usage / clear build cache |
| `docker compose up -d --build` | Build + start everything in the background |
| `docker compose ps` / `logs` / `restart app` / `down` | Manage the whole stack |

## Container networking

| Network type | Behaviour |
|---|---|
| **default bridge** | Containers get IPs but **can't find each other by name** |
| **user-defined bridge** (my `arena-net`) | Built-in DNS at `127.0.0.11`: `web` reaches the app as `http://app:3000` |
| **host** | Container shares the host's network (no isolation) |
| **none** | No network at all |

- **Publishing a port** (`ports:`) opens it on the host. My app publishes **nothing**: only containers on `arena-net` can reach it.
- `web` publishes `127.0.0.1:8080:8080`: only this machine can reach it, not the internet.
- ⚠️ **Docker bypasses UFW.** A port published as `8080:8080` (no IP) is open to the internet even if UFW blocks it, because Docker writes its own firewall rules. Always bind to `127.0.0.1` unless a port should be public. (My AWS security group would still block it, as a second layer.)
- Container IPs change when a container is recreated. That's why Nginx uses `resolver 127.0.0.11 valid=10s` and a variable in `proxy_pass`: it looks `app` up again instead of remembering an old IP.

## Volumes and persistent data
A container's own writable layer is **deleted with the container**. To keep data:

| Kind | Example | Use |
|---|---|---|
| **Named volume** | `arena-data:/data` | Data managed by Docker, survives `docker compose down` (not `down -v`) |
| **Bind mount** | `./config:/etc/app` | Share a host folder with a container (great for development) |
| **tmpfs** | `/tmp` | In-memory scratch space, gone on restart |

On AWS my game state is in **DynamoDB**, outside the container. That makes the containers **stateless and disposable**: Docker can kill and replace them at any time without losing anything. That's what makes the self-healing safe. Locally, the `arena-data` volume plays the same role.

## Environment variables and secrets
Where a container's settings come from, highest priority first:
1. `docker compose run -e` / `docker run -e`
2. `environment:` in the Compose file(s)
3. `env_file:`
4. `ENV` in the Dockerfile

That's why `HOST=127.0.0.1` from the Module 03 env file doesn't break the container: `environment: HOST: 0.0.0.0` wins.

Secrets:
- `ADMIN_TOKEN` comes from `/etc/chaos-arena/chaos-arena.env` (root-only) at **run time**. It is **never** in the image (`docker history` shows no trace) and never in Git.
- ⚠️ Environment variables are visible to anyone who can run `docker inspect`. That's one reason **Docker access = root access**, and why `ubuntu` is not in the `docker` group.
- Stronger options for later: Docker/Compose **secrets** (mounted as files), or AWS Secrets Manager.
- No AWS keys at all: the container gets temporary credentials from the EC2 metadata service. This needed **IMDS hop limit 2**, because the container is one network hop further away than the host.

## Docker Compose: what each part does

| Key | Meaning |
|---|---|
| `services:` | The containers (`app`, `web`) |
| `build:` / `image:` | Build from a Dockerfile, and what to tag the result |
| `restart: unless-stopped` | **Self-healing**: restart whenever the process exits, unless I stopped it myself |
| `init: true` | Tiny init as PID 1: forwards SIGTERM so the game saves on `docker compose stop` |
| `depends_on: condition: service_healthy` | Start `web` only once `app` passes its health check |
| `read_only`, `cap_drop: [ALL]`, `no-new-privileges` | Hardening |
| `deploy.resources.limits` | Resource quotas (memory, CPU, number of processes) |
| `networks:` / `volumes:` | Created and named by Compose (`chaos-arena_arena-net`, `chaos-arena_arena-data`) |
| `-f compose.yaml -f compose.aws.yaml` | **Override files**: same base everywhere, server-only differences on top |
| `logging: driver: awslogs` | Container output goes straight to CloudWatch Logs |

## Restart policies

| Policy | Restarts when… |
|---|---|
| `no` (default) | Never |
| `on-failure[:N]` | Exit code ≠ 0 (optionally max N times) |
| `always` | Any exit; also starts again after a daemon restart, even if I stopped it manually |
| `unless-stopped` (mine) | Any exit, except after I stopped it myself |

Docker waits 100 ms before the first restart and doubles the wait after each quick crash (100 ms, 200 ms, 400 ms… max 1 min). The wait resets once a container has run for 10 s. My 60 s CHAOS cooldown means it always restarts at the fastest speed.

⚠️ A restart policy reacts to the process **exiting**. An **unhealthy** but still-running container is **not** restarted by plain Docker. Module 05's monitoring and alarms cover that gap.

## Self-healing: Module 03 vs Module 04

| | systemd (M03) | Docker (M04) |
|---|---|---|
| Detects | Process exit | Container (process) exit |
| Restart delay | `RestartSec=2` (fixed 2 s) | 100 ms, growing only on repeated crashes |
| Measured recovery | ~3.0 s | ~0.8 s |
| Health checks | No (external only) | Built in (`HEALTHCHECK`), visible in `docker ps` |
