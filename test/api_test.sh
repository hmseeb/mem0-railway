#!/usr/bin/env bash
# Contract test for the mem0 API image.
#
# Covers exactly the things Railway needs and upstream's own image does not do:
# database migrations at boot, a postgres driver that actually loads on a slim
# base, an IPv6 listener (Railway's private network is IPv6 only), a writable
# history volume, and the pgvector collection getting created without an LLM
# call. No OpenAI key is used, so this never talks to a paid third party.
set -uo pipefail

IMAGE="${1:-ghcr.io/hmseeb/mem0-api:latest}"
SUFFIX="$$"
NET="mem0test-net-$SUFFIX"
PG="mem0test-pg-$SUFFIX"
API="mem0test-api-$SUFFIX"
PORT="${PORT:-18800}"
PGPASS="testpw-$SUFFIX"
BASE="http://127.0.0.1:$PORT"
FAILURES=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  printf '        expected: %s\n' "$2"
  printf '        actual:   %s\n' "$3"
  FAILURES=$((FAILURES + 1))
}

cleanup() {
  docker rm -f "$API" "$PG" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

echo "mem0 API contract test"
echo "image: $IMAGE"
echo

docker network create "$NET" >/dev/null || { echo "could not create docker network"; exit 1; }

docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_PASSWORD="$PGPASS" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=postgres \
  pgvector/pgvector:pg17 >/dev/null || { echo "could not start postgres"; exit 1; }

echo "waiting for postgres"
for _ in $(seq 1 60); do
  docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
if ! docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1; then
  echo "postgres never became ready. status and logs:"
  docker ps -a --filter "name=$PG" --format '{{.Status}}'
  docker logs "$PG" 2>&1 | tail -20
  exit 1
fi

# APP_DB_NAME=postgres puts the auth tables and the vector table in one database.
# Upstream splits them with an init script mounted into the postgres image, which
# Railway cannot do. MEM0_TELEMETRY=false keeps test runs out of mem0's analytics.
docker run -d --name "$API" --network "$NET" -p "$PORT:8000" \
  -e POSTGRES_HOST="$PG" \
  -e POSTGRES_PORT=5432 \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD="$PGPASS" \
  -e POSTGRES_DB=postgres \
  -e APP_DB_NAME=postgres \
  -e POSTGRES_COLLECTION_NAME=memories \
  -e JWT_SECRET="test-jwt-secret-not-a-real-one-$SUFFIX" \
  -e OPENAI_API_KEY="sk-contract-test-placeholder" \
  -e DASHBOARD_URL="http://localhost:3000" \
  -e MEM0_TELEMETRY=false \
  "$IMAGE" >/dev/null || { echo "could not start the api image"; exit 1; }

echo "waiting for the api"
READY=""
for _ in $(seq 1 120); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/auth/setup-status" 2>/dev/null)
  if [ "$CODE" = "200" ]; then READY=yes; break; fi
  if ! docker ps --format '{{.Names}}' | grep -q "^$API$"; then
    echo "container exited early. logs:"
    docker logs "$API" 2>&1 | tail -40
    break
  fi
  sleep 1
done
echo

# 1. Boots and serves. A 200 here also proves migrations ran and the postgres
#    driver loaded, because setup-status counts rows in a migrated table.
if [ "$READY" = "yes" ]; then
  pass "api answers on /auth/setup-status after boot"
else
  fail "api answers on /auth/setup-status after boot" "http 200 within 120s" "no response; last logs above"
fi

# 2. Migrations really ran: the users table exists in the app database.
TABLES=$(docker exec "$PG" psql -U postgres -d postgres -tAc \
  "select string_agg(tablename, ',' order by tablename) from pg_tables where schemaname='public'" 2>&1)
case "$TABLES" in
  *users*) pass "alembic created the app tables (found: $TABLES)" ;;
  *) fail "alembic created the app tables" "a 'users' table in the public schema" "$TABLES" ;;
esac

# 3. The vector extension is installed and the memory collection table exists.
#    Listing memories touches the pgvector store without embedding anything.
LIST=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/memories?user_id=contract-test")
if [ "$LIST" = "401" ] || [ "$LIST" = "403" ]; then
  pass "memory endpoints reject unauthenticated callers (http $LIST)"
else
  fail "memory endpoints reject unauthenticated callers" "http 401 or 403" "http $LIST"
fi

# 4. First admin registration works end to end (write path through the ORM).
REG=$(curl -s -X POST "$BASE/auth/register" -H 'Content-Type: application/json' \
  -d '{"name":"Contract Test","email":"contract@example.com","password":"contract-test-pw"}')
case "$REG" in
  *access_token*) pass "first admin registration returns a session" ;;
  *) fail "first admin registration returns a session" "a response containing access_token" "$REG" ;;
esac

TOKEN=$(printf '%s' "$REG" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

# 5. Registration closes after the first admin. This is the property that makes
#    a public deploy safe: nobody else can claim the instance.
REG2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/auth/register" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Intruder","email":"intruder@example.com","password":"intruder-pw-123"}')
if [ "$REG2" = "403" ]; then
  pass "registration closes after the first admin (http 403)"
else
  fail "registration closes after the first admin" "http 403" "http $REG2"
fi

# 6. API key issuance works, so machine clients have a way in.
KEY=$(curl -s -X POST "$BASE/api-keys" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"label":"contract test"}')
case "$KEY" in
  *'"key"'*) pass "an api key can be issued" ;;
  *) fail "an api key can be issued" "a response containing a key field" "$KEY" ;;
esac

# 7. Authenticated memory listing works, which forces the pgvector collection
#    table into existence without calling an embedding provider.
AUTHED=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/memories?user_id=contract-test" \
  -H "Authorization: Bearer $TOKEN")
if [ "$AUTHED" = "200" ]; then
  pass "authenticated memory listing returns 200"
else
  docker logs "$API" 2>&1 | tail -20
  fail "authenticated memory listing returns 200" "http 200" "http $AUTHED"
fi

VEC=$(docker exec "$PG" psql -U postgres -d postgres -tAc \
  "select count(*) from pg_extension where extname='vector'" 2>&1)
if [ "$VEC" = "1" ]; then
  pass "the vector extension is installed in the app database"
else
  fail "the vector extension is installed in the app database" "1" "$VEC"
fi

# 8. IPv6 listener. Railway's private network has no IPv4 at all, so a service
#    bound only to 0.0.0.0 is unreachable from its siblings.
V6=$(docker exec "$API" python -c \
  "import socket;s=socket.socket(socket.AF_INET6);s.settimeout(5);s.connect(('::1',8000));print('ok')" 2>&1)
if [ "$V6" = "ok" ]; then
  pass "the api accepts connections over IPv6"
else
  fail "the api accepts connections over IPv6" "a successful connect to ::1 port 8000" "$V6"
fi

# 9. The history directory is a real writable path, because Railway mounts a
#    volume there and the sqlite history file lives inside it.
HIST=$(docker exec "$API" sh -c 'touch /app/history/.writetest && echo ok && rm -f /app/history/.writetest' 2>&1)
if [ "$HIST" = "ok" ]; then
  pass "/app/history is writable"
else
  fail "/app/history is writable" "ok" "$HIST"
fi

# 10. Restarting must not wipe anything or fail on already-applied migrations.
docker restart "$API" >/dev/null 2>&1
for _ in $(seq 1 90); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/auth/setup-status" 2>/dev/null)
  [ "$CODE" = "200" ] && break
  sleep 1
done
STATUS=$(curl -s "$BASE/auth/setup-status")
case "$STATUS" in
  *false*) pass "the admin account survives a restart and migrations re-run cleanly" ;;
  *) fail "the admin account survives a restart" '{"needsSetup":false}' "$STATUS" ;;
esac

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS  all api contract checks green"
  exit 0
fi
echo "FAIL  $FAILURES api contract check(s) failed"
exit 1
