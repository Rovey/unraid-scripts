#!/bin/bash
set -euo pipefail

# Configuration
THRESHOLD=80                    # Trigger mover if usage exceeds this %
CACHE_PATH="/mnt/cache"         # Path to cache
LOG_TAG="MoverTrigger"

# Get usage of /mnt/cache only
USAGE=$(df -h "$CACHE_PATH" | awk 'NR==2 {print $5}' | tr -d '%')
if ! [[ "$USAGE" =~ ^[0-9]+$ ]]; then
  logger -t "$LOG_TAG" "ERROR: Could not determine cache usage."
  exit 1
fi

# Check if mover is already running
if pgrep -x mover > /dev/null; then
  logger -t "$LOG_TAG" "Mover already running. Skipping. Cache at ${USAGE}%."
  exit 0
fi

# Trigger mover if threshold is exceeded
if [ "$USAGE" -ge "$THRESHOLD" ]; then
  logger -t "$LOG_TAG" "Cache is ${USAGE}% full. Starting mover."
  /usr/local/sbin/mover start &> /dev/null &
fi
