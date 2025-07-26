#!/bin/bash

HOST=$1
LISTEN_PORT=$2

echo "Starting proxy for port ${LISTEN_PORT} -> ${HOST}:1${LISTEN_PORT}"
socat -v -v TCP4-LISTEN:${LISTEN_PORT},fork,reuseaddr \
    SYSTEM:"bash -c '/set-container-status.sh unpause ${HOST} >&2; exec socat -v -v STDIO TCP4:${HOST}:1${LISTEN_PORT}'" &
