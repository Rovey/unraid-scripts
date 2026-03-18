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
DRY_RUN=0   # Zet op 1 om alleen te loggen

# ==============================
# Cleanup Function
# ==============================

cleanup_path () {
    local TARGET_PATH="$1"
    local DAYS_OLD="$2"

    if [ ! -d "$TARGET_PATH" ]; then
        logger -t "$LOG_TAG" "Pad $TARGET_PATH bestaat niet. Overslaan."
        return
    fi

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
            logger -t "$LOG_TAG" "[DRY RUN] Zou verwijderen: $DIR"
        else
            logger -t "$LOG_TAG" "Verwijderen: $DIR"
            rm -rf -- "$DIR"
        fi
    done < <(find "$TARGET_PATH" -mindepth 1 -maxdepth 1 -type d -not -type l -mtime +"$DAYS_OLD" -print0)

    if [ "$found" -eq 0 ]; then
        logger -t "$LOG_TAG" "Geen oude mappen ouder dan $DAYS_OLD dagen in $TARGET_PATH."
    fi

    logger -t "$LOG_TAG" "Cleanup klaar voor $TARGET_PATH."
}

# ==============================
# Execute Cleanup
# ==============================

cleanup_path "$INCOMPLETE_PATH" "$DAYS_INCOMPLETE"
cleanup_path "$MOVIES_PATH" "$DAYS_COMPLETE"
cleanup_path "$TV_PATH" "$DAYS_COMPLETE"

logger -t "$LOG_TAG" "Volledige cleanup run voltooid."