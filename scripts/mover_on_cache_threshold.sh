#!/bin/bash
set -euo pipefail

# Configuration
THRESHOLD=80                    # Trigger mover if usage exceeds this %
CACHE_PATH="/mnt/cache"         # Path to cache
LOG_TAG="MoverTrigger"

log () { echo "[$(date '+%H:%M:%S')] $1"; logger -t "$LOG_TAG" "$1"; }

# Get usage of /mnt/cache only
USAGE=$(df "$CACHE_PATH" | awk 'NR==2 {print $5}' | tr -d '%')
if ! [[ "$USAGE" =~ ^[0-9]+$ ]]; then
  log "ERROR: Could not determine cache usage."
  exit 1
fi

# Check if mover is already running
if pgrep -f '/usr/local/sbin/mover' > /dev/null; then
  log "Mover already running. Skipping. Cache at ${USAGE}%."
  exit 0
fi

# Trigger mover if threshold is exceeded
if [ "$USAGE" -ge "$THRESHOLD" ]; then
  log "Cache is ${USAGE}% full. Starting mover."
  /usr/local/sbin/mover start >> /var/log/mover-trigger.log 2>&1 &
else
  log "Cache at ${USAGE}%. Below threshold (${THRESHOLD}%). No action."
fi
