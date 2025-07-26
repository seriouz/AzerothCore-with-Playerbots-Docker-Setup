#!/bin/bash

set -e

CHECK_INTERVAL=60   # Check every minute
IDLE_TIMEOUT=300    # 5 minutes (in seconds)
AUTH_HOST="ac-authserver"
AUTH_PORT=3724
WORLD_HOST="ac-worldserver"
WORLD_PORT=8085

log_message() {
    logger -t azeroth-monitor "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1"
}

has_world_connections() {
    # Count only ESTABLISHED connections
    local conn_1=$(ss -Htn state established "sport = :${AUTH_PORT}" | wc -l)
    local conn_2=$(ss -Htn state established "sport = :${WORLD_PORT}" | wc -l)
    local total=$((conn_1 + conn_2))
    
    log_message "Active AzerothCore connections: $total (Auth $AUTH_PORT: $conn_1, World $WORLD_PORT: $conn_2)"
    [ $total -gt 0 ]
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

/start-proxy.sh $AUTH_HOST $AUTH_PORT
/start-proxy.sh $WORLD_HOST $WORLD_PORT

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
