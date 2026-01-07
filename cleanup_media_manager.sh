#!/usr/bin/env bash
#
# cleanup_media_manager.sh
#
# Manager para backup / move (quarantine) / upload (rclone) e restore de mídias referenciadas por Tickets.
# Organização por run em ${HOME_BASE} (default /home/ubuntu/cleanup).
#
# IMPORTANT:
# - Por segurança o script gera previews (com echo) e ACTION scripts (sem echo) mas NÃO torna os ACTION scripts executáveis.
#   Execute ACTION scripts manualmente com `sudo bash /home/ubuntu/cleanup/runs/run_YYYYMMDD_HHMMSS/do_move_cmds.sh`.
# - Configure RCLONE_REMOTE e RCLONE_CONFIG no topo do script (uma vez) ou passe --rclone-remote ao executar.
#
# EXAMPLES (copiar/colar):
#  - Executar com variáveis padrão (dry-run, DAYS=15):
#      sudo /home/ubuntu/cleanup/cleanup_media_manager.sh
#
#  - Dry-run (gera CSV e previews) com 5 dias:
#      sudo /home/ubuntu/cleanup/cleanup_media_manager.sh --days 5
#
#  - Apenas backup (create timestamped backup; no move):
#      sudo /home/ubuntu/cleanup/cleanup_media_manager.sh --days 5 --do-backup
#
#  - Apenas move (move ALL candidates older than DAYS; use --limit N for testing):
#      sudo /home/ubuntu/cleanup/cleanup_media_manager.sh --days 5 --do-move
#
#  - Move + upload to Backblaze B2 + delete this run's files from quarantine on success:
#      sudo /home/ubuntu/cleanup/cleanup_media_manager.sh --days 5 --do-move --push-remote --delete-quarantine-after-push
#    (use --rclone-remote 'yourremote:yourbucket/path' to override the default remote defined in the script)
#
# NOTES:
# - The script assumes access to Docker (psql inside container) and the media volume path.
# - You may place the script in another folder; set --home-base to change output layout.
# - BACKUPS are stored under ${HOME_BASE}/backups/media_backup_<timestamp>
# - Quarantine (fixed) is ${HOME_BASE}/quarantine
# - Runs artifacts are stored in ${HOME_BASE}/runs/run_<timestamp>
#
set -euo pipefail

# ---------------------------
# Defaults (user prefs)
# ---------------------------
DAYS=15
HOME_BASE="/home/ubuntu/cleanup"   # change if you want artifacts somewhere else
MEDIA_ROOT="/var/lib/docker/volumes/ticketz-docker-acme_backend_public/_data"
DB_CONTAINER="ticketz-docker-acme-postgres-1"
DB_NAME="ticketz"
DB_USER="ticketz"

DO_BACKUP="${DO_BACKUP:-0}"   # Padrão: não fazer backup ✅
DO_MOVE="${DO_MOVE:-1}"       # Padrão: SIM mover ✅
PUSH_REMOTE="${PUSH_REMOTE:-1}" # Padrão: SIM enviar rclone ✅

# SINGLE rclone remote variable (set here once; can override with --rclone-remote)
RCLONE_REMOTE="yourremote:yourbucket/path/to/media"
# path to rclone config (use your user rclone config so sudo calls also find it)
RCLONE_CONFIG="/home/ubuntu/.config/rclone/rclone.conf"

DELETE_QUAR_AFTER_PUSH=1
LIMIT=0      # 0 = all (move all candidates)
PRUNE_KEEP=5 # keep last N local backups (0 = disable)
VERBOSE=1

# ---------------------------
# Parse CLI args
# ---------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2;;
    --home-base) HOME_BASE="$2"; shift 2;;
    --media-root) MEDIA_ROOT="$2"; shift 2;;
    --db-container) DB_CONTAINER="$2"; shift 2;;
    --db-name) DB_NAME="$2"; shift 2;;
    --db-user) DB_USER="$2"; shift 2;;
    --do-backup) DO_BACKUP=1; shift;;
    --do-move) DO_MOVE=1; shift;;
    --push-remote) PUSH_REMOTE=1; shift;;
    --rclone-remote) RCLONE_REMOTE="$2"; shift 2;;
    --delete-quarantine-after-push) DELETE_QUAR_AFTER_PUSH=1; shift;;
    --limit) LIMIT="$2"; shift 2;;
    --prune-keep) PRUNE_KEEP="$2"; shift 2;;
    --quiet) VERBOSE=0; shift;;
    --verbose) VERBOSE=1; shift;;
    --help) cat <<EOF
Usage: $0 [options]
Options:
  --days N                    Consider messages older than N days (default ${DAYS})
  --home-base PATH            Base dir for artifacts (default ${HOME_BASE})
  --media-root PATH           Media root (default ${MEDIA_ROOT})
  --do-backup                 Perform timestamped backup (rsync)
  --do-move                   Move selected files to quarantine (fixed dir ${HOME_BASE}/quarantine)
  --push-remote               After move, upload quarantine files to remote (RCLONE_REMOTE)
  --rclone-remote NAME/PATH   Override RCLONE_REMOTE for this run
  --delete-quarantine-after-push
                              After successful push, delete only this run's files from quarantine
  --limit N                   When moving, limit to first N files (0 = all)
  --prune-keep N              Keep last N local backups (0 = disable)
  --help
EOF
      exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

log() { [[ $VERBOSE -gt 0 ]] && echo "[$(date +'%F %T')] $*"; }

# ---------------------------
# Setup run paths
# ---------------------------
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${HOME_BASE}/runs/run_${TIMESTAMP}"
BACKUP_DIR="${HOME_BASE}/backups/media_backup_${TIMESTAMP}"
QUAR_DIR="${HOME_BASE}/quarantine"          # fixed quarantine dir
LOG_FILE="${RUN_DIR}/run.log"
CSV_FILE="${RUN_DIR}/media_ticket_candidates.csv"
CANDIDATES_LIST="${RUN_DIR}/media_ticket_candidates.txt"
MOVED_LIST="${RUN_DIR}/moved_list.txt"
PREVIEW_DELETE="${RUN_DIR}/preview_delete_cmds.sh"
PREVIEW_MOVE="${RUN_DIR}/preview_move_cmds.sh"
DO_DELETE_SCRIPT="${RUN_DIR}/do_delete_cmds.sh"
DO_MOVE_SCRIPT="${RUN_DIR}/do_move_cmds.sh"
RCLONE_LIST="${RUN_DIR}/rclone_files_list.txt"

sudo mkdir -p "${HOME_BASE}" "${RUN_DIR}" "${HOME_BASE}/backups" "${QUAR_DIR}"
sudo chown -R "$USER":"$USER" "${HOME_BASE}" || true

log "Run dir: ${RUN_DIR}"
log "Media root: ${MEDIA_ROOT}"
log "Quarantine dir: ${QUAR_DIR}"
log "Backup dir (if used): ${BACKUP_DIR}"
log "Rclone remote in use: ${RCLONE_REMOTE}"
log "Rclone config file: ${RCLONE_CONFIG}"

# ---------------------------
# Step 1: export mediaUrl from DB
# ---------------------------
log "Exporting mediaUrl from DB (ticketId IS NOT NULL and older than ${DAYS} days)..."
SQL="SELECT DISTINCT \"mediaUrl\" FROM \"Messages\" WHERE \"mediaUrl\" IS NOT NULL AND \"ticketId\" IS NOT NULL AND \"createdAt\" < now() - interval '${DAYS} days';"
sudo docker exec -i "${DB_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" -At -c "${SQL}" > "${RUN_DIR}/media_ticket_db_raw.txt"
log "DB raw lines: $(wc -l < "${RUN_DIR}/media_ticket_db_raw.txt")"

# ---------------------------
# Step 2: normalize DB list
# ---------------------------
sed 's|^media/||; /^$/d' "${RUN_DIR}/media_ticket_db_raw.txt" | sort -u > "${RUN_DIR}/media_ticket_db.txt"
log "DB unique entries: $(wc -l < "${RUN_DIR}/media_ticket_db.txt")"

# ---------------------------
# Step 3: filesystem listing
# ---------------------------
sudo find "${MEDIA_ROOT}/media" -type f -printf '%P\n' 2>/dev/null | sort -u > "${RUN_DIR}/media_fs.txt"
log "FS files under media/: $(wc -l < "${RUN_DIR}/media_fs.txt")"

# ---------------------------
# Step 4: intersection -> candidates
# ---------------------------
comm -12 "${RUN_DIR}/media_fs.txt" "${RUN_DIR}/media_ticket_db.txt" > "${CANDIDATES_LIST}"
log "Candidates (DB ∩ FS): $(wc -l < "${CANDIDATES_LIST}")"

# ---------------------------
# Step 5: write CSV (persistent)
# ---------------------------
log "Generating CSV at ${CSV_FILE}"
echo "size_mb,mtime_iso,relpath,abs_path" > "${CSV_FILE}"
while IFS= read -r rel; do
  fp="${MEDIA_ROOT}/media/${rel}"
  if [[ -f "$fp" ]]; then
    size_bytes=$(stat -c%s "$fp" 2>/dev/null || echo 0)
    size_mb=$(awk "BEGIN{printf \"%.2f\", $size_bytes/1024/1024}")
    mtime=$(stat -c %y "$fp" 2>/dev/null || echo "")
    printf '%s,"%s","%s","%s"\n' "$size_mb" "$mtime" "$rel" "$fp" >> "${CSV_FILE}"
  fi
done < "${CANDIDATES_LIST}"
log "CSV created lines: $(wc -l < "${CSV_FILE}")"

# ---------------------------
# Step 6: previews (echo) for review
# ---------------------------
log "Generating preview scripts (for review) in ${RUN_DIR}"
sed "s|^|echo sudo rm -v -- '${MEDIA_ROOT}/media/'|" "${CANDIDATES_LIST}" > "${PREVIEW_DELETE}"
chmod 644 "${PREVIEW_DELETE}"

: > "${PREVIEW_MOVE}"
while IFS= read -r rel; do
  printf 'echo sudo mkdir -p "%s/%s" && echo sudo mv -v -- "%s/media/%s" "%s/%s/"\n' "${QUAR_DIR}" "$(dirname "$rel")" "${MEDIA_ROOT}" "$rel" "${QUAR_DIR}" "$(dirname "$rel")" >> "${PREVIEW_MOVE}"
done < "${CANDIDATES_LIST}"
chmod 644 "${PREVIEW_MOVE}"

# ---------------------------
# Step 7: ACTION scripts (real commands) - generated but NOT executable by default
# ---------------------------
log "Generating ACTION scripts (do_move/do_delete) in ${RUN_DIR} (NOT executable by default)"
: > "${DO_DELETE_SCRIPT}"
: > "${DO_MOVE_SCRIPT}"
while IFS= read -r rel; do
  echo "sudo rm -v -- '${MEDIA_ROOT}/media/${rel}'" >> "${DO_DELETE_SCRIPT}"
  echo "sudo mkdir -p '${QUAR_DIR}/$(dirname "$rel")' && sudo mv -v -- '${MEDIA_ROOT}/media/${rel}' '${QUAR_DIR}/$(dirname "$rel")/'" >> "${DO_MOVE_SCRIPT}"
done < "${CANDIDATES_LIST}"
chmod 644 "${DO_DELETE_SCRIPT}" "${DO_MOVE_SCRIPT}"

# ---------------------------
# Step 8: perform backup (optional)
# ---------------------------
if [[ "${DO_BACKUP}" -eq 1 ]]; then
  log "Performing backup via rsync to ${BACKUP_DIR} ..."
  sudo mkdir -p "${BACKUP_DIR}"
  sudo rsync -av --files-from="${CANDIDATES_LIST}" "${MEDIA_ROOT}/media/" "${BACKUP_DIR}/" 2>&1 | tee -a "${LOG_FILE}" || { echo "rsync failed"; exit 1; }
  log "Backup completed: $(sudo du -sh "${BACKUP_DIR}" 2>/dev/null || true)"
  if [[ ${PRUNE_KEEP} -gt 0 ]]; then
    log "Pruning local backups - keeping last ${PRUNE_KEEP}"
    cd "${HOME_BASE}/backups"
    ls -1dt media_backup_* | tail -n +$((PRUNE_KEEP+1)) | xargs -r sudo rm -rf --
  fi
else
  log "DRY-RUN backup (no files copied). To copy, re-run with --do-backup"
fi

# ---------------------------
# Step 9: perform move to quarantine (optional)
# ---------------------------
if [[ "${DO_MOVE}" -eq 1 ]]; then
  log "Moving files to quarantine ${QUAR_DIR} (limit=${LIMIT})"
  sudo mkdir -p "${QUAR_DIR}"
  > "${MOVED_LIST}"
  src_list="${CANDIDATES_LIST}"
  if [[ ${LIMIT} -gt 0 ]]; then
    src_list="${RUN_DIR}/candidates_limit.txt"
    head -n "${LIMIT}" "${CANDIDATES_LIST}" > "${src_list}"
  fi
  moved=0
  while IFS= read -r rel; do
    src="${MEDIA_ROOT}/media/${rel}"
    if ! sudo test -f "${src}"; then
      log "SKIP not found: ${src}"
      continue
    fi
    dest="${QUAR_DIR}/$(dirname "${rel}")"
    sudo mkdir -p "${dest}"
    sudo mv -v -- "${src}" "${dest}/" 2>&1 | tee -a "${LOG_FILE}"
    echo "${rel}" >> "${MOVED_LIST}"
    moved=$((moved+1))
  done < "${src_list}"
  log "Move complete. Files moved: ${moved}"
  log "Quarantine size: $(sudo du -sh "${QUAR_DIR}" 2>/dev/null || true)"
else
  log "DO_MOVE not set. No files moved."
fi

# ---------------------------
# Step 10: optionally push to remote via rclone
# ---------------------------
if [[ "${PUSH_REMOTE}" -eq 1 ]]; then
  log "Using rclone remote: ${RCLONE_REMOTE}"
  cp "${CANDIDATES_LIST}" "${RCLONE_LIST}"
  log "Running rclone copy ${QUAR_DIR}/ -> ${RCLONE_REMOTE} using files-from ${RCLONE_LIST}"
  if sudo rclone --config "${RCLONE_CONFIG}" copy "${QUAR_DIR}/" "${RCLONE_REMOTE}" --files-from "${RCLONE_LIST}" --progress --log-file="${RUN_DIR}/rclone_upload.log" --log-level INFO 2>&1 | tee -a "${LOG_FILE}"; then
    log "rclone upload completed successfully. Log: ${RUN_DIR}/rclone_upload.log"
    if [[ "${DELETE_QUAR_AFTER_PUSH}" -eq 1 ]]; then
      log "Deleting only this run's files from quarantine (as requested)..."
      del_list="${MOVED_LIST}"
      if [[ ! -f "${del_list}" ]]; then del_list="${CANDIDATES_LIST}"; fi
      while IFS= read -r rel; do
        qf="${QUAR_DIR}/${rel}"
        if [[ -f "${qf}" ]]; then
          sudo rm -v -- "${qf}" 2>&1 | tee -a "${LOG_FILE}"
        fi
      done < "${del_list}"
      sudo find "${QUAR_DIR}" -type d -empty -delete || true
      log "Deleted run's files from quarantine"
    fi
  else
    echo "ERROR: rclone upload failed (see ${RUN_DIR}/rclone_upload.log). Quarantine NOT modified."
    exit 2
  fi
fi

# ---------------------------
# Step 11: generate restore scripts (backup/quarantine/remote)
# ---------------------------
RESTORE_FROM_BACKUP="${RUN_DIR}/restore_from_backup_${TIMESTAMP}.sh"
RESTORE_FROM_QUAR="${RUN_DIR}/restore_from_quarantine_${TIMESTAMP}.sh"
RESTORE_FROM_REMOTE="${RUN_DIR}/restore_from_remote_${TIMESTAMP}.sh"

# restore from backup
cat > "${RESTORE_FROM_BACKUP}" <<'REST'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 /path/to/backup_dir /path/to/run_dir"; exit 1
fi
BACKUP_DIR="$1"
RUN_DIR="$2"
MEDIA_ROOT="/var/lib/docker/volumes/ticketz-docker-acme_backend_public/_data"
while IFS= read -r rel; do
  src="$BACKUP_DIR/$rel"
  dst_dir="$MEDIA_ROOT/media/$(dirname "$rel")"
  if [[ -f "$src" ]]; then
    sudo mkdir -p "$dst_dir"
    sudo cp -v "$src" "$dst_dir/" || echo "WARN copy failed: $src"
  else
    echo "Missing in backup: $src"
  fi
done < "${RUN_DIR}/media_ticket_candidates.txt"
REST
chmod 644 "${RESTORE_FROM_BACKUP}"

# restore from quarantine
cat > "${RESTORE_FROM_QUAR}" <<'REST'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/run_dir"; exit 1
fi
RUN_DIR="$1"
MEDIA_ROOT="/var/lib/docker/volumes/ticketz-docker-acme_backend_public/_data"
QUAR_DIR="/home/ubuntu/cleanup/quarantine"
while IFS= read -r rel; do
  src="$QUAR_DIR/$rel"
  dst_dir="$MEDIA_ROOT/media/$(dirname "$rel")"
  if [[ -f "$src" ]]; then
    sudo mkdir -p "$dst_dir"
    sudo mv -v "$src" "$dst_dir/" || echo "WARN mv failed: $src"
  else
    echo "Not found in quarantine: $src"
  fi
done < "${RUN_DIR}/media_ticket_candidates.txt"
REST
chmod 644 "${RESTORE_FROM_QUAR}"

# restore from remote (uses the ubuntu rclone config file)
cat > "${RESTORE_FROM_REMOTE}" <<'REST'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <rclone_remote> /path/to/run_dir"; exit 1
fi
RCLONE_REMOTE="$1"
RUN_DIR="$2"
MEDIA_ROOT="/var/lib/docker/volumes/ticketz-docker-acme_backend_public/_data"
TMP_RESTORE="/tmp/restore_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$TMP_RESTORE"
# point rclone to ubuntu's config so sudo calls work
sudo rclone --config /home/ubuntu/.config/rclone/rclone.conf copy "${RCLONE_REMOTE}" "${TMP_RESTORE}" --files-from "${RUN_DIR}/media_ticket_candidates.txt" --progress --log-file "${RUN_DIR}/rclone_restore.log" --log-level INFO
while IFS= read -r rel; do
  src="${TMP_RESTORE}/${rel}"
  if [[ -f "$src" ]]; then
    dst_dir="${MEDIA_ROOT}/media/$(dirname "$rel")"
    sudo mkdir -p "$dst_dir"
    sudo mv -v "$src" "$dst_dir/" || echo "WARN mv failed: $src"
  else
    echo "Not restored from remote (missing): $rel"
  fi
done < "${RUN_DIR}/media_ticket_candidates.txt"
sudo rm -rf "${TMP_RESTORE}"
REST
chmod 644 "${RESTORE_FROM_REMOTE}"

log "Generated artifacts in ${RUN_DIR}:"
ls -lh "${RUN_DIR}" || true

log "===== SUMMARY ====="
log "Run dir: ${RUN_DIR}"
log "Candidates: $(wc -l < "${CANDIDATES_LIST}")"
log "CSV: ${CSV_FILE}"
log "Preview delete: ${PREVIEW_DELETE}"
log "Preview move: ${PREVIEW_MOVE}"
log "Action move (script, non-executable): ${DO_MOVE_SCRIPT}"
log "Action delete (script, non-executable): ${DO_DELETE_SCRIPT}"
log "Restore scripts: ${RESTORE_FROM_BACKUP}, ${RESTORE_FROM_QUAR}, ${RESTORE_FROM_REMOTE}"
log "Log file: ${LOG_FILE}"
log "Backup dir (if created): ${BACKUP_DIR}"
log "Quarantine dir: ${QUAR_DIR}"
log "Done."
exit 0
