#!/bin/bash

set -e

# Load environment variables from .env file if it exists
if [ -f "/env/conf.env" ]; then
    export $(grep -v '^#' /env/conf.env | xargs)
fi

CHECK_INTERVAL=60   # Check every minute
IDLE_TIMEOUT=300    # 5 minutes (in seconds)
AUTH_HOST="ac-authserver"
AUTH_PORT=3724
WORLD_HOST="ac-worldserver"
WORLD_PORT=8085
WORLD_TELNET_PORT=3443

log_message() {
    logger -t azeroth-monitor "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1"
}

get_connected_players() {
    local host="${WORLD_HOST}"
    local port="${WORLD_TELNET_PORT}"
    local user="${RA_USERNAME:-admin}"
    local pass="${RA_PASSWORD:-adminpass}"

    # Versuche, via Telnet zu verbinden und Spielerzahl auszulesen
    local output
    output=$(
        {
            sleep 1
            echo "$user"
            sleep 1
            echo "$pass"
            sleep 1
            echo ".server info"
            sleep 1
            echo "exit"
        } | busybox telnet "$host" "$port" 2>/dev/null
    )

    if [[ $? -ne 0 || -z "$output" ]]; then
        log_message "Telnet to $host:$port failed or returned no output"
        return 1  # Fehler
    fi

    local players
    players=$(echo "$output" | grep -oP 'Connected players: \K\d+')

    if [[ -z "$players" ]]; then
        log_message "Could not parse connected players from telnet output"
        return 1  # Fehler
    fi

    echo "$players"
    return 0
}

has_world_connections() {
    local conn_auth=$(ss -Htn state established "sport = :${AUTH_PORT}" | wc -l)
    local players

    if ! players=$(get_connected_players); then
        log_message "Skipping pause: Unable to determine player count from telnet"
        return 0  # Verhindere Pausieren
    fi

    log_message "Active AzerothCore connections: Auth $AUTH_PORT: $conn_auth, Players online: ${players:-0}"

    [ "$conn_auth" -gt 0 ] || [ "$players" -gt 0 ]
}


# Function to freeze both servers
freeze_servers() {
    /set-container-status.sh pause $AUTH_HOST
    /set-container-status.sh pause $WORLD_HOST
}

# Initialize
log_message "Monitor script starting"
mkdir -p /tmp
echo $(date +%s) > /tmp/azeroth_last_activity
log_message "Initial setup complete"

echo "$AUTH_HOST:$AUTH_PORT" >> /tmp/proxy-registrations.txt

/start-proxy.sh

# Main loop
while true; do
    log_message "Starting check iteration..."

    if has_world_connections; then
        # Update last activity time if there are connections
        echo $(date +%s) > /tmp/azeroth_last_activity
        log_message "Activity detected - updating last activity time"
    else
        # Calculate idle time
        last_activity=$(cat /tmp/azeroth_last_activity 2>/dev/null || echo 0)
        current_time=$(date +%s)
        idle_time=$((current_time - last_activity))
        log_message "No activity - idle for $idle_time seconds"
        
        if [ $idle_time -ge $IDLE_TIMEOUT ]; then
            log_message "Servers idle for ${idle_time} seconds. Freezing..."
            freeze_servers
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
