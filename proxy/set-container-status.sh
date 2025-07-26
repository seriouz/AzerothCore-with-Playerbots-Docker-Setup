#!/bin/bash

# Usage check
if [[ "$1" != "pause" && "$1" != "unpause" ]]; then
  echo "Usage: $0 [pause|unpause]"
  exit 1
fi

ACTION="$1"
shift

containers=("$@")

if [ "${#containers[@]}" -eq 0 ]; then
  echo "No containers provided."
  exit 1
fi

TARGET_STATE="paused"
OPPOSITE_STATE="running"

if [[ "$ACTION" == "pause" ]]; then
  TARGET_STATE="running"
  OPPOSITE_STATE="paused"
fi

for container in "${containers[@]}"; do
  state=$(curl --silent --unix-socket /var/run/docker.sock \
    http://localhost/containers/${container}/json | jq -r '.State.Status')

  if [[ "$state" == "$TARGET_STATE" ]]; then
    echo "[*] Executing $ACTION on $container"
    curl --silent --unix-socket /var/run/docker.sock -X POST \
      http://localhost/containers/${container}/$ACTION
  else
    echo "[-] Skipping $container (state: $state ≠ $TARGET_STATE)"
  fi
done

sleep 0.5