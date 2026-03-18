#!/bin/bash
set -euo pipefail
umask 077

PROJECT="/mnt/user/appdata/imap-cleaner"
ENV_FILE="$PROJECT/.env"
PY_FILE="$PROJECT/imap_cleanup.py"
LOGDIR="$PROJECT/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/scheduler-$(date +'%Y-%m-%d_%H-%M-%S').log"

# Clean up logs older than 7 days
find "$LOGDIR" -name "scheduler-*.log" -type f -mtime +7 -delete 2>/dev/null || true

echo "[$(date)] Scheduler started" | tee -a "$LOG"

# 0) Sanity
if [[ ! -f "$ENV_FILE" ]]; then echo "[$(date)] ERROR: $ENV_FILE not found" | tee -a "$LOG"; exit 1; fi
if [[ ! -f "$PY_FILE"  ]]; then echo "[$(date)] ERROR: $PY_FILE not found"  | tee -a "$LOG"; exit 1; fi

# 1) Wait for Docker
echo "[$(date)] Waiting for Docker..." | tee -a "$LOG"
for i in {1..24}; do
  if docker info >/dev/null 2>&1; then
    echo "[$(date)] Docker is up" | tee -a "$LOG"
    break
  fi
  sleep 5
  if [[ $i -eq 24 ]]; then
    echo "[$(date)] ERROR: Docker not ready in time" | tee -a "$LOG"; exit 1
  fi
done

# 2) Read IMAP host/port from .env without sourcing (safe with spaces)
getenv () { grep -E "^[[:space:]]*$1=" "$ENV_FILE" | tail -n1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//'; }
IMAP_HOST="$(getenv IMAP_HOST)"; [[ -z "$IMAP_HOST" ]] && IMAP_HOST="$(getenv IMAP_SERVER)"
IMAP_PORT="$(getenv IMAP_PORT)"; [[ -z "$IMAP_PORT" ]] && IMAP_PORT="993"
[[ -z "$IMAP_HOST" ]] && IMAP_HOST="imap.mail.me.com"

# Validate host/port to prevent command injection
if [[ ! "$IMAP_HOST" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[$(date)] ERROR: Invalid IMAP_HOST: $IMAP_HOST" | tee -a "$LOG"; exit 1
fi
if [[ ! "$IMAP_PORT" =~ ^[0-9]+$ ]]; then
  echo "[$(date)] ERROR: Invalid IMAP_PORT: $IMAP_PORT" | tee -a "$LOG"; exit 1
fi

# 3) Wait for DNS/TCP (best-effort, no shell interpolation)
echo "[$(date)] Waiting for DNS + TCP ${IMAP_HOST}:${IMAP_PORT}..." | tee -a "$LOG"
for i in {1..18}; do
  if timeout 5 bash -c "echo > /dev/tcp/$IMAP_HOST/$IMAP_PORT" 2>/dev/null; then
    echo "[$(date)] IMAP reachable" | tee -a "$LOG"; break
  fi
  sleep 5
  if [[ $i -eq 18 ]]; then
    echo "[$(date)] WARNING: IMAP not reachable after 90s — continuing anyway" | tee -a "$LOG"
  fi
done

# 4) Run Docker directly
ARGS='--mark-read --delete --mailboxes "INBOX,Junk"'
echo "[$(date)] Launching container with args: $ARGS" | tee -a "$LOG"
docker run --rm \
  --env-file "$ENV_FILE" \
  -v "$PROJECT":/work:ro \
  -v "$LOGDIR":/work/logs:rw \
  -w /work \
  python:3.12-alpine \
  sh -lc 'pip install --no-cache-dir -q --disable-pip-version-check --root-user-action=ignore python-dotenv==1.1.0 requests==2.32.3 && python imap_cleanup.py '"$ARGS" 2>&1 | tee -a "$LOG"
st=${PIPESTATUS[0]}

echo "[$(date)] Finished with exit code: $st" | tee -a "$LOG"
exit $st
