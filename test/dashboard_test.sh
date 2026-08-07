#!/usr/bin/env bash
# Contract test for the mem0 dashboard image.
#
# The one thing that must not break: the public API address is baked into the
# built javascript as a literal placeholder and swapped at container start. If a
# start command replaces the image entrypoint, or the swap misses a file, the
# browser ends up calling a URL named after the setting instead of the server.
set -uo pipefail

IMAGE="${1:-ghcr.io/hmseeb/mem0-dashboard:latest}"
SUFFIX="$$"
DASH="mem0test-dash-$SUFFIX"
PORT="${PORT:-13300}"
API_URL="https://api.contract-test.example"
INSTANCE="Contract Test Memory"
BASE="http://127.0.0.1:$PORT"
FAILURES=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  printf '        expected: %s\n' "$2"
  printf '        actual:   %s\n' "$3"
  FAILURES=$((FAILURES + 1))
}

cleanup() { docker rm -f "$DASH" >/dev/null 2>&1; }
trap cleanup EXIT

echo "mem0 dashboard contract test"
echo "image: $IMAGE"
echo

docker run -d --name "$DASH" -p "$PORT:3000" \
  -e NEXT_PUBLIC_API_URL="$API_URL" \
  -e NEXT_PUBLIC_INSTANCE_NAME="$INSTANCE" \
  -e API_INTERNAL_URL="http://127.0.0.1:9" \
  "$IMAGE" >/dev/null || { echo "could not start the dashboard image"; exit 1; }

echo "waiting for the dashboard"
READY=""
for _ in $(seq 1 90); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/health" 2>/dev/null)
  if [ "$CODE" = "200" ]; then READY=yes; break; fi
  if ! docker ps --format '{{.Names}}' | grep -q "^$DASH$"; then
    echo "container exited early. logs:"
    docker logs "$DASH" 2>&1 | tail -40
    break
  fi
  sleep 1
done
echo

# 1. It boots and serves.
if [ "$READY" = "yes" ]; then
  pass "dashboard answers on /api/health"
else
  fail "dashboard answers on /api/health" "http 200 within 90s" "no response; last logs above"
fi

# 2. The real API address made it into the built assets.
FOUND=$(docker exec "$DASH" sh -c "grep -rl '$API_URL' .next/ 2>/dev/null | head -3")
if [ -n "$FOUND" ]; then
  pass "the public api address was substituted into the built assets"
else
  fail "the public api address was substituted into the built assets" \
    "at least one file under .next containing $API_URL" "no match"
fi

# 3. No placeholder survived. This is the failure that shows up only in a
#    browser, as requests to a host named after the setting.
LEFTOVER=$(docker exec "$DASH" sh -c "grep -rl 'NEXT_PUBLIC_API_URL' .next/ 2>/dev/null | head -3")
if [ -z "$LEFTOVER" ]; then
  pass "no unsubstituted placeholder is left in the built assets"
else
  fail "no unsubstituted placeholder is left in the built assets" \
    "no files containing the raw placeholder" "$LEFTOVER"
fi

# 4. The instance name is substituted too, so operators can brand the install.
NAME_FOUND=$(docker exec "$DASH" sh -c "grep -rl '$INSTANCE' .next/ 2>/dev/null | head -1")
if [ -n "$NAME_FOUND" ]; then
  pass "the instance name was substituted into the built assets"
else
  fail "the instance name was substituted into the built assets" \
    "at least one file containing $INSTANCE" "no match"
fi

# 5. The image entrypoint does the substitution, so a Railway start command must
#    never replace it. Assert the entrypoint is still what upstream ships.
EP=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE" 2>&1)
case "$EP" in
  *entrypoint.sh*) pass "the image keeps its substitution entrypoint ($EP)" ;;
  *) fail "the image keeps its substitution entrypoint" "an entrypoint ending in entrypoint.sh" "$EP" ;;
esac

# 6. IPv6 listener, same reason as the api: Railway private networking has no IPv4.
V6=$(docker exec "$DASH" node -e \
  "const n=require('net');const s=n.connect(3000,'::1',()=>{console.log('ok');process.exit(0)});s.on('error',e=>{console.log(e.code);process.exit(1)});" 2>&1)
if [ "$V6" = "ok" ]; then
  pass "the dashboard accepts connections over IPv6"
else
  fail "the dashboard accepts connections over IPv6" "a successful connect to ::1 port 3000" "$V6"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS  all dashboard contract checks green"
  exit 0
fi
echo "FAIL  $FAILURES dashboard contract check(s) failed"
exit 1
