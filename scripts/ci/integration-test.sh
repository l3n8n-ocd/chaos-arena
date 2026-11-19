#!/usr/bin/env bash
# =============================================================================
# integration-test.sh — runs inside the CI/CD pipeline (Module 05)
#
# Starts the REAL containers with Docker Compose (local mode, no AWS) and
# checks the whole system works end to end:
#   1. both containers become healthy
#   2. the web page and the API answer through the web container
#   3. gameplay works and is saved
#   4. CHAOS crashes the app, Docker restarts it, the game continues
#
# Usage:  scripts/ci/integration-test.sh          (from the repo root)
# Expects the images chaos-arena-app:local and chaos-arena-web:local to exist.
# =============================================================================
set -euo pipefail

BASE="http://127.0.0.1:8080"
export CHAOS_COOLDOWN_SEC=5
COMPOSE=(docker compose -f compose.yaml)

fail() { echo "::error::$*"; "${COMPOSE[@]}" logs --tail 40 || true; exit 1; }
step() { echo; echo "==> $*"; }
json() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);console.log(process.argv[1].split(".").reduce((v,k)=>v?.[k],o))})' "$1"; }

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

step "Starting the containers (no build: using the images built by the pipeline)"
"${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 90 || fail "containers did not become healthy"
"${COMPOSE[@]}" ps

step "Web page and API answer through the web container"
curl -sf "$BASE/" | grep -q '<title>Chaos Arena</title>' || fail "web page not served"
curl -sf "$BASE/health" | grep -q ok || fail "web container /health failed"
HEALTH="$(curl -sf "$BASE/api/health")" || fail "/api/health failed"
echo "$HEALTH"
[[ "$(json status <<<"$HEALTH")" == "ok" ]] || fail "app not ok"
if [[ -n "${EXPECTED_VERSION:-}" ]]; then
  [[ "$(json version <<<"$HEALTH")" == "$EXPECTED_VERSION" ]] || fail "wrong version (expected $EXPECTED_VERSION)"
  echo "Image reports the expected version: $EXPECTED_VERSION"
fi
curl -sf "$BASE/api/status" | grep -q '"status":"ok"' || fail "/api/status not ok"

step "The app container is not published to the host"
if curl -s -m 2 http://127.0.0.1:3000/api/health >/dev/null; then fail "port 3000 should not be reachable"; fi
echo "OK: port 3000 is closed outside Docker"

step "Gameplay: pull the rope"
STATE="$(curl -sf -X POST -H 'Content-Type: application/json' -d '{"team":"red","count":7,"pid":"ci-player-1"}' "$BASE/api/pull")"
[[ "$(json rope <<<"$STATE")" == "-7" ]] || fail "rope did not move"
echo "rope = -7"

step "CHAOS: crash the app on purpose"
BEFORE="$(docker inspect -f '{{.RestartCount}}' chaos-arena-app-1)"
curl -sf -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/chaos" | grep -q crashing || fail "chaos refused"
START="$(date +%s%3N)"
sleep 0.3
HEALED=0
for _ in $(seq 1 150); do
  if curl -sf -m 1 "$BASE/api/health" >/dev/null; then HEALED=1; break; fi
  sleep 0.1
done
[[ "$HEALED" -eq 1 ]] || fail "app did not come back within 15 s"
AFTER="$(docker inspect -f '{{.RestartCount}}' chaos-arena-app-1)"
[[ "$AFTER" -gt "$BEFORE" ]] || fail "Docker did not restart the container"
echo "Docker restarted the container ($BEFORE -> $AFTER restarts), answering again after $(( $(date +%s%3N) - START )) ms"

STATE="$(curl -sf "$BASE/api/state")"
[[ "$(json rope <<<"$STATE")" == "-7" ]] || fail "game state was lost in the crash"
[[ "$(json chaos.total <<<"$STATE")" == "1" ]] || fail "crash not counted"
RECOVERY="$(json chaos.lastRecoveryMs <<<"$STATE")"
[[ "$RECOVERY" =~ ^[0-9]+$ ]] || fail "recovery time not recorded"
echo "Game survived the crash (rope still -7). Recovery measured by the app: ${RECOVERY} ms"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "| Integration test | ✅ passed: CHAOS crash healed by Docker in **${RECOVERY} ms**, game state kept |" >> "$GITHUB_STEP_SUMMARY"
fi

step "Cooldown: a second CHAOS right away is refused"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/chaos")"
[[ "$CODE" == "429" ]] || fail "expected 429 during cooldown, got $CODE"
echo "OK: 429 during cooldown"

echo
echo "All integration checks passed."
