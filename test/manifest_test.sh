#!/usr/bin/env bash
# Checks a published image runs on the hardware Railway actually has.
#
# This exists because mem0's own published server image is built for arm64 only.
# It looks fine locally on an Apple laptop and is completely unrunnable on
# Railway. A green build tells you nothing about this; only the manifest does.
set -uo pipefail

FAILURES=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  printf '        expected: %s\n' "$2"
  printf '        actual:   %s\n' "$3"
  FAILURES=$((FAILURES + 1))
}

check() {
  local image="$1"
  local platforms
  platforms=$(docker buildx imagetools inspect "$image" --format '{{range .Manifest.Manifests}}{{.Platform.OS}}/{{.Platform.Architecture}} {{end}}' 2>&1)

  case "$platforms" in
    *linux/amd64*) pass "$image runs on linux/amd64" ;;
    *) fail "$image runs on linux/amd64" "linux/amd64 in the manifest" "$platforms" ;;
  esac

  case "$platforms" in
    *linux/arm64*) pass "$image runs on linux/arm64" ;;
    *) fail "$image runs on linux/arm64" "linux/arm64 in the manifest" "$platforms" ;;
  esac
}

echo "published image manifest test"
echo

for image in "${@:-ghcr.io/hmseeb/mem0-api:latest ghcr.io/hmseeb/mem0-dashboard:latest}"; do
  check "$image"
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS  all published images are multi-arch"
  exit 0
fi
echo "FAIL  $FAILURES manifest check(s) failed"
exit 1
