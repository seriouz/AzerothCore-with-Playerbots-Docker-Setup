#!/bin/bash

HOST=$1
LISTEN_PORT=$2
REG_FILE="/tmp/proxy-registrations.txt"
CONTAINERS=()

# Collect all container names (HOSTs)
while IFS=: read -r HOST PORT; do
  CONTAINERS+=("$HOST")
done < "$REG_FILE"

# Remove duplicates
CONTAINERS=($(printf "%s\n" "${CONTAINERS[@]}" | sort -u))

# Start socat for each registered listener
while IFS=: read -r HOST PORT; do
  echo "[*] Starting proxy for port $PORT -> $HOST:$PORT"

  CONTAINER_ARGS=$(printf "'%s' " "${CONTAINERS[@]}")

  socat -v -v TCP4-LISTEN:$PORT,fork,reuseaddr \
    SYSTEM:"bash -c 'echo \"[+] Incoming connection on $PORT\" >&2; \
      /set-container-status.sh unpause $CONTAINER_ARGS >&2; \
      exec socat -v -v STDIO TCP4:$HOST:$PORT'" &

done < "$REG_FILE"