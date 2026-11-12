#!/usr/bin/env bash
# =============================================================================
# 04-verify.sh  —  Module 04, Step 4
#
# Tests the containerised deployment and prints an evidence report:
# Docker engine, images + layers, containers + health, hardening + quotas,
# networking, volumes, environment variables + secrets, logs, the live site,
# and (with --chaos) a real crash with Docker restarting the container.
#
# Usage:    sudo ./04-verify.sh <domain> [--chaos] | tee ~/module-04-verify-output.txt
# Example:  sudo ./04-verify.sh chaos-arena.duckdns.org --chaos | tee ~/module-04-verify-output.txt
# =============================================================================
set -u   # no "set -e": keep reporting even if one check fails

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0 $*" >&2
  exit 1
fi

DOMAIN=""
RUN_CHAOS=0
for arg in "$@"; do
  case "$arg" in
    --chaos) RUN_CHAOS=1 ;;
    *) DOMAIN="$arg" ;;
  esac
done
[[ -n "$DOMAIN" ]] || { echo "Usage: sudo $0 <domain> [--chaos]" >&2; exit 1; }

APP=chaos-arena-app-1
WEB=chaos-arena-web-1
SITE="https://$DOMAIN"
RESOLVE="--resolve $DOMAIN:443:127.0.0.1"
RESOLVE_ARGS=(--resolve "$DOMAIN:443:127.0.0.1")

section() { echo; echo "=================== $1 ==================="; }
run()     { echo "\$ $*"; bash -c "$*" 2>&1; echo; }
pretty()  { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.stringify(JSON.parse(s),null,2))}catch{console.log(s)}})'; }
export -f pretty

echo "Chaos Arena — Module 04 verification report"
echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

section "1. DOCKER ENGINE"
run "docker version --format 'Client {{.Client.Version}} | Engine {{.Server.Version}}' && docker compose version"
run "cat /etc/docker/daemon.json"
run "systemctl is-active docker && systemctl is-enabled docker"
echo "# The ubuntu user is NOT in the docker group (docker access = root access):"
run "id -nG ubuntu | tr ' ' '\n' | grep -cx docker || true"

section "2. IMAGES (Dockerfile -> image)"
run "docker image ls --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' | grep -E 'REPOSITORY|chaos-arena'"
echo "# Layers of the app image (multi-stage build: only runtime files are shipped):"
run "docker history chaos-arena-app:local --format '{{.Size}}\t{{.CreatedBy}}' | head -n 10 | cut -c1-100"
run "docker image inspect chaos-arena-app:local --format 'User: {{.Config.User}} | Workdir: {{.Config.WorkingDir}} | Cmd: {{.Config.Cmd}}'"

section "3. CONTAINERS (image -> running container)"
run "arena ps 2>/dev/null"
run "docker inspect $APP $WEB --format '{{.Name}}: health={{.State.Health.Status}} restartPolicy={{.HostConfig.RestartPolicy.Name}} restarts={{.RestartCount}} init={{.HostConfig.Init}} user={{.Config.User}}'"
echo "# Old Module 03 service is off (the containers replaced it):"
run "systemctl is-active chaos-arena; systemctl is-enabled chaos-arena"

section "4. HARDENING & RESOURCE QUOTAS"
run "docker inspect $APP $WEB --format '{{.Name}}: readOnlyRoot={{.HostConfig.ReadonlyRootfs}} capDrop={{.HostConfig.CapDrop}} securityOpt={{.HostConfig.SecurityOpt}}'"
run "docker inspect $APP $WEB --format '{{.Name}}: memoryLimit={{.HostConfig.Memory}} nanoCpus={{.HostConfig.NanoCpus}} pidsLimit={{.HostConfig.PidsLimit}}'"
run "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}' $APP $WEB"
echo "# Writing to the app's code is impossible:"
run "docker exec $APP sh -c 'touch /app/hacked' || true"

section "5. CONTAINER NETWORKING"
run "docker network ls --filter name=chaos-arena --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'"
run "docker network inspect chaos-arena_arena-net --format '{{range .Containers}}{{.Name}} -> {{.IPv4Address}}{{println}}{{end}}'"
echo "# Published ports: the app has NONE, web only on 127.0.0.1:"
run "docker port $APP; echo '(app: nothing published)'; docker port $WEB"
run "ss -tlnp | grep -E ':(3000|8080)\\b' | awk '{print \$4, \$6}'"
echo "# The web container finds the app by its service name (Docker DNS):"
run "docker exec $WEB nslookup app 127.0.0.11 2>/dev/null | grep -A1 'Name:'"
echo "# From the host, the app's port 3000 is closed (only reachable inside Docker):"
run "curl -s -m 2 http://127.0.0.1:3000/api/health || echo 'connection refused: OK'"

section "6. VOLUMES & PERSISTENT DATA"
run "docker volume ls --filter name=chaos-arena"
run "docker inspect $APP --format '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}} (rw={{.RW}}){{println}}{{end}}'"
echo "# On AWS the game state lives in DynamoDB (outside the container), so the container itself is disposable:"
run "docker exec $APP printenv STORE TABLE_NAME"

section "7. ENVIRONMENT VARIABLES & SECRETS"
echo "# Variables inside the app container (secret hidden):"
run "docker exec $APP printenv | grep -E '^(NODE_ENV|HOST|PORT|STORE|AWS_REGION|TABLE_NAME|BUCKET_NAME|WIN_AT|CHAOS_COOLDOWN_SEC|TRUST_PROXY|ADMIN_TOKEN)=' | sed -E 's/^(ADMIN_TOKEN)=.*/\1=******** (hidden)/' | sort"
echo "# The secret comes from the root-only file, not from the image or Git:"
run "stat -c '%A %U:%G %n' /etc/chaos-arena/chaos-arena.env"
run "docker history --no-trunc chaos-arena-app:local | grep -c ADMIN_TOKEN || true"
echo "# No AWS access keys: the container uses the server's IAM role:"
run "docker exec $APP printenv | grep -c AWS_ACCESS_KEY || true"

section "8. LOGS"
run "docker inspect $APP --format 'app log driver: {{.HostConfig.LogConfig.Type}} {{.HostConfig.LogConfig.Config}}'"
run "docker inspect $WEB --format 'web log driver: {{.HostConfig.LogConfig.Type}}'"
run "arena logs --no-log-prefix --tail 4 app 2>/dev/null | cut -c1-180"

section "9. LIVE WEB APPLICATION (HTTPS -> host Nginx -> web -> app)"
run "curl -s $RESOLVE $SITE/health"
run "curl -s $RESOLVE $SITE/api/health"
run "curl -s -m 10 $RESOLVE $SITE/api/status | pretty"
run "curl -sI $RESOLVE $SITE/ | grep -Ei '^(HTTP|server|strict-transport|content-security|x-frame|x-content)'"
run "curl -s $RESOLVE $SITE/ | grep -o '<title>.*</title>'"

if [[ "$RUN_CHAOS" -eq 1 ]]; then
  section "10. CHAOS TEST (Docker restarts the crashed container)"
  BEFORE="$(docker inspect -f '{{.RestartCount}}' $APP)"
  SINCE="$(date -u +%Y-%m-%dT%H:%M:%S)"
  echo "Container restarts so far: $BEFORE"
  echo "\$ curl -X POST $SITE/api/chaos"
  START_MS="$(date +%s%3N)"
  RESPONSE="$(curl -s "${RESOLVE_ARGS[@]}" -X POST -H 'Content-Type: application/json' -d '{"pid":"verify-script"}' "$SITE/api/chaos")"
  echo "$RESPONSE"
  if grep -q '"status":"crashing"' <<<"$RESPONSE"; then
    HEALED=0
    sleep 0.2
    for _ in $(seq 1 100); do
      if curl -sf -m 1 "${RESOLVE_ARGS[@]}" "$SITE/api/health" >/dev/null; then HEALED=1; break; fi
      sleep 0.1
    done
    END_MS="$(date +%s%3N)"
    echo
    if [[ "$HEALED" -eq 1 ]]; then
      echo "RESULT: healed. Answering again $((END_MS - START_MS)) ms after the CHAOS request."
    else
      echo "RESULT: NOT healed within 10 seconds. Check: arena ps / arena logs app"
    fi
    echo "Container restarts now: $(docker inspect -f '{{.RestartCount}}' $APP)"
    echo
    echo "# Docker's own event log (the container died with exit code 1, then started again):"
    echo "\$ docker events --since $SINCE --filter container=$APP --filter event=die --filter event=start"
    docker events --since "$SINCE" --until "$(date -u +%Y-%m-%dT%H:%M:%S)" --filter "container=$APP" \
      --filter event=die --filter event=start \
      --format '{{.TimeNano}} {{.Action}}{{if eq .Action "die"}} (exit code {{index .Actor.Attributes "exitCode"}}){{end}}' |
      while read -r nanos action rest; do
        echo "$(date -u -d "@$((nanos / 1000000000)).$(printf '%09d' $((nanos % 1000000000)) | cut -c1-3)" +%H:%M:%S.%3N) container $action $rest"
      done
    echo
    echo "# What the app recorded in DynamoDB:"
    run "curl -s $RESOLVE $SITE/api/state | pretty | grep -A 7 '\"chaos\"'"
    run "arena logs --no-log-prefix --since 2m app 2>/dev/null | grep -E 'CHAOS|deliberate crash|recovered from crash|listening' | tail -n 4 | cut -c1-180"
  else
    echo "(The chaos button is cooling down. Wait a minute and run again.)"
  fi
else
  section "10. CHAOS TEST"
  echo "(skipped: add --chaos to crash the app container on purpose)"
fi

echo
echo "=================== END OF REPORT ==================="
