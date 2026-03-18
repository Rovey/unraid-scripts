#!/bin/bash
set -euo pipefail
umask 077

# =========================
# CONFIG
# =========================
export RCLONE_CONFIG="/boot/config/rclone/rclone.conf"

LOCAL="/mnt/user/backups/appdata"
REMOTE_BASE="gdrive:UnraidBackups"
REMOTE="$REMOTE_BASE/appdata"

# Caps:
# - HARD: never exceed this (stay safely under your 15GB drive)
# - SOFT: allowed right after upload (temporary)
# - FINAL: prune target when needed
FINAL_CAP_GB=10
SOFT_CAP_GB=12
HARD_CAP_MIB=$((14*1024 + 512))          # 14.5 GiB in MiB (NEVER exceed)
FINAL_CAP_MIB=$((FINAL_CAP_GB * 1024))
SOFT_CAP_MIB=$((SOFT_CAP_GB * 1024))

# Retention minimums during pruning (won't prune below these)
MIN_KEEP_AB=3
MIN_KEEP_FLASH=12

# Selection policy for upload set
# Upload newest ab_* runs until budget is exhausted (but keep it sane)
MIN_UPLOAD_AB=1
MAX_UPLOAD_AB=10
SAFETY_MIB=200                           # keep a buffer under HARD cap

# rclone performance/retry
TRANSFERS=4
CHECKERS=8
RETRIES=3
LOW_LEVEL_RETRIES=10

# Logs (rotating)
LOG_DIR="/mnt/user/backups/appdata/rclone-logs"
LOG_KEEP=30
mkdir -p "$LOG_DIR"
exec 9>"$LOG_DIR/.lock"
flock -n 9 || { echo "[WARN] Already running"; exit 0; }
LOG_FILE="$LOG_DIR/rclone-gdrive-$(date +%F-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
ls -1t "$LOG_DIR"/rclone-gdrive-*.log 2>/dev/null | tail -n +$((LOG_KEEP+1)) | xargs -r rm -f --

echo "[INFO] ===== RCLONE GDRIVE BACKUP START $(date '+%Y-%m-%d %H:%M:%S') ====="
echo "[INFO] Local : $LOCAL"
echo "[INFO] Remote: $REMOTE"
echo "[INFO] Log   : $LOG_FILE"
echo "[INFO] Caps  : FINAL=${FINAL_CAP_GB}GB, SOFT=${SOFT_CAP_GB}GB, HARD=14.5GB"

# =========================
# HELPERS
# =========================
remote_used_mib () {
  # Prefer JSON bytes; fallback to text; retry.
  local bytes out i
  out=$(rclone size "$REMOTE" --json 2>/dev/null || true)
  if [[ -n "$out" ]]; then
    bytes=$(echo "$out" | tr -d '[:space:]' | grep -o '"bytes":[0-9]*' | head -n1 | grep -o '[0-9]*' || true)
    if [[ -n "${bytes:-}" ]]; then
      echo $(( (bytes + 1024*1024 - 1) / (1024*1024) ))
      return 0
    fi
  fi

  for i in 1 2 3; do
    out=$(rclone size "$REMOTE" 2>/dev/null | awk '
      /Total size:/ {
        val=$3; unit=$4
        gsub(/,/, ".", val)
        if (unit=="B")        mib = val/1024/1024
        else if (unit=="KiB") mib = val/1024
        else if (unit=="MiB") mib = val
        else if (unit=="GiB") mib = val*1024
        else if (unit=="TiB") mib = val*1024*1024
        else mib = val
        printf "%.0f\n", mib
        exit
      }')
    if [[ -n "${out:-}" ]]; then echo "$out"; return 0; fi
    sleep 1
  done
  echo "[WARN] Failed to determine remote size after all retries" >&2
  echo -1
}

count_ab () { rclone lsf "$REMOTE" --dirs-only 2>/dev/null | grep -E '^ab_' | wc -l || true; }
count_flash () { rclone lsf "$REMOTE/flash-config" 2>/dev/null | grep -E '\.zip$' | wc -l || true; }
oldest_ab () { rclone lsf "$REMOTE" --dirs-only 2>/dev/null | grep -E '^ab_' | sort | head -n1 || true; }
oldest_flash () { rclone lsf "$REMOTE/flash-config" 2>/dev/null | grep -E '^flash-config-.*\.zip$' | sort | head -n1 || true; }

prune_remote_to_target () {
  local target_mib="$1"
  echo "[INFO] Prune pass to target ${target_mib} MiB on $REMOTE"

  local used abn flashn item
  while :; do
    used=$(remote_used_mib)
    if (( used < 0 )); then
      echo "[WARN] Cannot determine remote size during pruning. Stopping."
      break
    fi
    if (( used <= target_mib )); then
      echo "[INFO] Under target. (used ${used} MiB)"
      break
    fi

    abn=$(count_ab); abn=${abn:-0}
    if (( abn > MIN_KEEP_AB )); then
      item="$(oldest_ab)"
      [[ -z "${item:-}" ]] && break
      [[ "$item" =~ ^ab_[0-9_]+/$ ]] || { echo "[WARN] Unexpected ab name: $item"; break; }
      echo "[INFO] Purging oldest ab run: $item"
      rclone purge "$REMOTE/$item" --log-level INFO
      continue
    fi

    flashn=$(count_flash); flashn=${flashn:-0}
    if (( flashn > MIN_KEEP_FLASH )); then
      item="$(oldest_flash)"
      [[ -z "${item:-}" ]] && break
      [[ "$item" =~ ^flash-config-[0-9-]+\.zip$ ]] || { echo "[WARN] Unexpected flash name: $item"; break; }
      echo "[INFO] Deleting oldest flash zip: $item"
      rclone deletefile "$REMOTE/flash-config/$item" --log-level INFO
      continue
    fi

    echo "[WARN] Over target but can't prune further (min keeps reached)."
    break
  done

  used=$(remote_used_mib)
  if (( used >= 0 )); then
    echo "[INFO] Prune pass finished. Remote used: ${used} MiB"
  else
    echo "[WARN] Prune pass finished. Could not determine final remote usage."
  fi
}

# =========================
# MAIN
# =========================

# Ensure remote folders exist before measuring
rclone mkdir "$REMOTE" >/dev/null 2>&1 || true
rclone mkdir "$REMOTE/flash-config" >/dev/null 2>&1 || true

used_before=$(remote_used_mib)
if (( used_before < 0 )); then
  echo "[ERROR] Cannot determine remote size. Aborting."
  exit 1
fi
echo "[INFO] Remote used before any action: ${used_before} MiB"

# If already at/over HARD cap, prune to SOFT cap first so we can upload safely
if (( used_before >= HARD_CAP_MIB )); then
  echo "[WARN] Remote at/over HARD cap. Pruning to SOFT cap before upload..."
  prune_remote_to_target "$SOFT_CAP_MIB"
else
  echo "[INFO] Remote is under HARD cap. No mandatory pre-prune."
fi

used_now=$(remote_used_mib)
if (( used_now < 0 )); then
  echo "[ERROR] Cannot determine remote size before upload. Aborting."
  exit 1
fi
echo "[INFO] Remote used before upload: ${used_now} MiB"

# Build upload budget to ensure we never exceed HARD cap
budget_mib=$(( HARD_CAP_MIB - used_now - SAFETY_MIB ))
if (( budget_mib < 0 )); then budget_mib=0; fi
echo "[INFO] Upload budget to stay under HARD cap: ${budget_mib} MiB (safety ${SAFETY_MIB} MiB)"

UPLOAD_ITEMS=()

# Include flash-config if it exists and fits
FLASH_LOCAL="$LOCAL/flash-config"
if [[ -d "$FLASH_LOCAL" ]]; then
  flash_mib=$(du -sm "$FLASH_LOCAL" | awk '{print $1}' || echo 0)
  if (( flash_mib <= budget_mib )); then
    UPLOAD_ITEMS+=( "$FLASH_LOCAL" )
    budget_mib=$(( budget_mib - flash_mib ))
    echo "[INFO] flash-config included (~${flash_mib} MiB). Remaining budget: ${budget_mib} MiB"
  else
    echo "[WARN] Not enough budget to upload flash-config this run."
  fi
fi

# Select newest ab_* runs until budget exhausted (min 1 if present), max MAX_UPLOAD_AB
mapfile -t AB_ALL < <(ls -1dt "$LOCAL"/ab_* 2>/dev/null || true)
AB_TO_UPLOAD=()

for ab in "${AB_ALL[@]}"; do
  ab_mib=$(du -sm "$ab" | awk '{print $1}' || echo 0)

  if (( ab_mib > budget_mib )); then
    echo "[WARN] Skipping $ab (${ab_mib} MiB) — exceeds remaining budget (${budget_mib} MiB)"
    continue
  fi

  AB_TO_UPLOAD+=( "$ab" )
  budget_mib=$(( budget_mib - ab_mib ))

  if (( ${#AB_TO_UPLOAD[@]} >= MAX_UPLOAD_AB )); then
    break
  fi
done

if (( ${#AB_TO_UPLOAD[@]} == 0 )); then
  echo "[WARN] No ab_* folders found locally to upload."
else
  UPLOAD_ITEMS+=( "${AB_TO_UPLOAD[@]}" )
fi

if (( ${#UPLOAD_ITEMS[@]} == 0 )); then
  echo "[WARN] Nothing selected for upload. Skipping upload step."
else
  echo "[INFO] Uploading selected items one-by-one (rclone only accepts 1 src)..."
  printf '[INFO] Items:\n'
  printf ' - %s\n' "${UPLOAD_ITEMS[@]}"

  for src in "${UPLOAD_ITEMS[@]}"; do
    base="$(basename "$src")"
    echo "[INFO] rclone copy: $src -> $REMOTE/$base"

    rclone copy "$src" "$REMOTE/$base" \
      --exclude "*-flash-backup-*.zip" \
      --fast-list \
      --transfers "$TRANSFERS" --checkers "$CHECKERS" \
      --retries "$RETRIES" --low-level-retries "$LOW_LEVEL_RETRIES" \
      --log-level INFO
  done
fi

# Post-check and prune if needed
used_after=$(remote_used_mib)
if (( used_after < 0 )); then
  echo "[WARN] Cannot determine remote size after upload — skipping post-upload pruning"
  used_after=0
fi
echo "[INFO] Remote used after upload: ${used_after} MiB"

if (( used_after > HARD_CAP_MIB )); then
  echo "[ERROR] Remote exceeded HARD cap unexpectedly. Pruning immediately to FINAL cap."
  prune_remote_to_target "$FINAL_CAP_MIB"
elif (( used_after > SOFT_CAP_MIB )); then
  echo "[INFO] Above SOFT cap; pruning down to FINAL cap (${FINAL_CAP_GB}GB)."
  prune_remote_to_target "$FINAL_CAP_MIB"
else
  echo "[INFO] Under SOFT cap after upload. No pruning needed."
  # If you ALWAYS want to end at 10GB, uncomment:
  # prune_remote_to_target "$FINAL_CAP_MIB"
fi

final_used=$(remote_used_mib)
if (( final_used >= 0 )); then
  echo "[INFO] Done. Final remote used: ${final_used} MiB"
else
  echo "[WARN] Done. Could not determine final remote usage."
fi
echo "[INFO] ===== RCLONE GDRIVE BACKUP END $(date '+%Y-%m-%d %H:%M:%S') ====="
