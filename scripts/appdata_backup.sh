#!/bin/bash
set -euo pipefail
umask 077

# ===== SETTINGS =====
DST="/mnt/user/backups/appdata/flash-config"
KEEP_LAST=5          # Always keep the newest N backups
KEEP_WEEKS=8         # Keep 1 per week for last N weeks
KEEP_MONTHS=12       # Keep 1 per month for last N months
# ====================

echo "[INFO] Flash-config backup started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "[INFO] Destination: $DST"

mkdir -p "$DST"
if [[ ! -d "$DST" ]]; then
  echo "[ERROR] DST does not exist: $DST"
  exit 1
fi

shopt -s nullglob

# --- Create backup ---
OUT="$DST/flash-config-$(date +%F-%H%M).zip"
echo "[INFO] Creating flash-config backup: $OUT"
cd /boot
zip -qr "$OUT" config
unzip -t "$OUT" >/dev/null 2>&1 || { echo "[ERROR] Corrupt backup: $OUT"; rm -f "$OUT"; exit 1; }
echo "[INFO] Backup created: $(ls -lh "$OUT" | awk '{print $5, $9}')"

# ===== Retention / cleanup =====
echo "[INFO] Cleaning up old flash-config backups..."

KEEP_LIST=$(mktemp "$DST/.keep.XXXXXX")
trap 'rm -f "$KEEP_LIST"' EXIT

# Helper: pick newest file from an array
pick_newest () {
  ls -1t -- "$@" 2>/dev/null | head -n 1 || true
}

# Backups are named like: flash-config-YYYY-MM-DD-HHMM.zip
extract_date () {
  local base="$1"
  local d="${base#flash-config-}"
  d="${d%.zip}"
  echo "${d:0:10}"    # YYYY-MM-DD
}

# Collect all backups (sorted newest first)
all=( "$DST"/flash-config-????-??-??-????.zip )

if (( ${#all[@]} == 0 )); then
  echo "[INFO] No flash-config backups found."
  exit 0
fi

# 1) Always keep newest N
mapfile -t newestN < <(ls -1t "$DST"/flash-config-????-??-??-????.zip 2>/dev/null | head -n "$KEEP_LAST" || true)
if (( ${#newestN[@]} )); then
  printf "%s\n" "${newestN[@]}" >> "$KEEP_LIST"
fi

# 2) Keep 1 per week for last KEEP_WEEKS weeks (based on filename date)
for i in $(seq 0 $((KEEP_WEEKS-1))); do
  weekkey=$(date -d "last sunday -$i week" +%G-%V)

  mapfile -t matches < <(
    for f in "${all[@]}"; do
      base=$(basename "$f")
      d=$(extract_date "$base")
      wk=$(date -d "$d" +%G-%V 2>/dev/null || true)
      [[ "$wk" == "$weekkey" ]] && echo "$f"
    done
  )

  if (( ${#matches[@]} )); then
    newest=$(pick_newest "${matches[@]}")
    [[ -n "$newest" ]] && echo "$newest" >> "$KEEP_LIST"
  fi
done

# 3) Keep 1 per month for last KEEP_MONTHS months
for i in $(seq 0 $((KEEP_MONTHS-1))); do
  monthkey=$(date -d "$i month ago" +%Y-%m)

  mapfile -t matches < <(
    for f in "${all[@]}"; do
      base=$(basename "$f")
      d=$(extract_date "$base")
      [[ "${d:0:7}" == "$monthkey" ]] && echo "$f"
    done
  )

  if (( ${#matches[@]} )); then
    newest=$(pick_newest "${matches[@]}")
    [[ -n "$newest" ]] && echo "$newest" >> "$KEEP_LIST"
  fi
done

# De-duplicate keep list (important when newestN overlaps with week/month picks)
sort -u "$KEEP_LIST" -o "$KEEP_LIST"

# Delete everything not in keep list
to_delete=$(grep -vxFf "$KEEP_LIST" < <(printf "%s\n" "${all[@]}") || true)
if [[ -n "$to_delete" ]]; then
  echo "[INFO] Deleting:"
  echo "$to_delete"
  while IFS= read -r f; do
    rm -f -- "$f"
  done <<< "$to_delete"
else
  echo "[INFO] Nothing to delete."
fi

echo "[INFO] Flash-config backup finished: $(date '+%Y-%m-%d %H:%M:%S')"
