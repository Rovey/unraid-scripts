#!/bin/bash
set -euo pipefail

# ==============================
# Configuration
# ==============================

# Paden
INCOMPLETE_PATH="/mnt/user/data/usenet/incomplete"
MOVIES_PATH="/mnt/user/data/usenet/complete/movies"
TV_PATH="/mnt/user/data/usenet/complete/tv"

# Leeftijd thresholds (dagen)
DAYS_INCOMPLETE=7
DAYS_COMPLETE=14

LOG_TAG="UsenetCleanup"
DELETED_COUNT=0
DRY_RUN="${1:-0}"   # Pass 1 as argument for dry-run mode

# ==============================
# Cleanup Function
# ==============================

cleanup_path () {
    local TARGET_PATH="$1"
    local DAYS_OLD="$2"

    if [ ! -d "$TARGET_PATH" ]; then
        logger -t "$LOG_TAG" "Path $TARGET_PATH does not exist. Skipping."
        return
    fi

    # Resolve to real path for containment checks
    TARGET_PATH="$(realpath -- "$TARGET_PATH")"

    local found=0
    while IFS= read -r -d '' DIR; do
        found=1
        # Skip symlinks — prevent traversal outside target
        if [ -L "$DIR" ]; then
            logger -t "$LOG_TAG" "SKIP (symlink): $DIR"
            continue
        fi
        # Verify realpath stays inside target
        local realdir
        realdir=$(realpath -- "$DIR" 2>/dev/null) || continue
        case "$realdir" in
            "$TARGET_PATH"/*) ;;
            *) logger -t "$LOG_TAG" "SKIP (outside target): $DIR"; continue ;;
        esac

        if [ "$DRY_RUN" -eq 1 ]; then
            logger -t "$LOG_TAG" "[DRY RUN] Would delete: $DIR"
        else
            logger -t "$LOG_TAG" "Deleting: $DIR"
            rm -rf -- "$DIR" || logger -t "$LOG_TAG" "ERROR: Failed to remove $DIR"
            : $(( DELETED_COUNT++ ))
        fi
    done < <(find "$TARGET_PATH" -mindepth 1 -maxdepth 1 -type d -not -type l -mtime +"$DAYS_OLD" -print0)

    if [ "$found" -eq 0 ]; then
        logger -t "$LOG_TAG" "No directories older than $DAYS_OLD days in $TARGET_PATH."
    fi

    logger -t "$LOG_TAG" "Cleanup complete for $TARGET_PATH."
}

# ==============================
# Execute Cleanup
# ==============================

cleanup_path "$INCOMPLETE_PATH" "$DAYS_INCOMPLETE"
cleanup_path "$MOVIES_PATH" "$DAYS_COMPLETE"
cleanup_path "$TV_PATH" "$DAYS_COMPLETE"

logger -t "$LOG_TAG" "Full cleanup run completed. $DELETED_COUNT directories removed."