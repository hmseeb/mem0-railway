#!/bin/sh
# Boot script for the mem0 API server.
#
# Railway starts every service at once, so postgres is usually not accepting
# connections yet on the first attempt. Retrying alembic covers both waiting for
# the database and applying migrations, in one loop.
set -e

# Railway mounts the history volume over whatever the image had here.
mkdir -p "$(dirname "${HISTORY_DB_PATH:-/app/history/history.db}")"

attempt=0
until alembic upgrade head; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    echo "database did not become reachable after $attempt attempts, giving up" >&2
    exit 1
  fi
  echo "database not ready yet, retrying in 2s (attempt $attempt/30)"
  sleep 2
done

if [ "$#" -eq 0 ]; then
  # serve.py, not the uvicorn CLI: it binds one socket that answers on both IPv4
  # and IPv6, which the CLI cannot do. See the comment in serve.py.
  set -- python serve.py
fi

exec "$@"
