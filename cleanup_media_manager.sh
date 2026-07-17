#!/usr/bin/env bash
#
# cleanup_media_manager.sh
#
# Manager para backup / move (quarantine) / upload (rclone) e restore de mídias
# referenciadas por Tickets do Ticketz.
#
# IMPORTANTE:
# - NÃO edite este script diretamente para configurar seu ambiente.
# - Copie .env_cleanup_exemplo para .env_cleanup e ajuste os valores lá.
# - Execute sempre via: sudo /home/ubuntu/cleanup/cleanup_media_manager.sh
#
set -euo pipefail

# ---------------------------
# Load environment config
# ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env_cleanup"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

# ---------------------------
# Defaults (fallbacks)
# ---------------------------
DAYS="${DAYS:-15}"
HOME_BASE="${HOME_BASE:-/home/ubuntu/cleanup}"
MEDIA_ROOT="${MEDIA_ROOT:-/var/lib/docker/volumes/ticketz-docker-acme_backend_public/_data}"
DB_CONTAINER="${DB_CONTAINER:-ticketz-docker-acme-postgres-1}"
DB_NAME="${DB_NAME:-ticketz}"
DB_USER="${DB_USER:-ticketz}"

DO_BACKUP="${DO_BACKUP:-0}"
DO_MOVE="${DO_MOVE:-1}"
PUSH_REMOTE="${PUSH_REMOTE:-1}"

RCLONE_REMOTE="${RCLONE_REMOTE:-yourremote:yourbucket/path/to/media}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/home/ubuntu/.config/rclone/rclone.conf}"

S3_PUBLIC_URL="${S3_PUBLIC_URL:-}"

DELETE_QUAR_AFTER_PUSH="${DELETE_QUAR_AFTER_PUSH:-1}"
UPDATE_DB_AFTER_PUSH="${UPDATE_DB_AFTER_PUSH:-1}"
LIMIT="${LIMIT:-0}"
PRUNE_KEEP="${PRUNE_KEEP:-5}"
VERBOSE="${VERBOSE:-1}"

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
    --no-backup) DO_BACKUP=0; shift;;
    --do-move) DO_MOVE=1; shift;;
    --no-move) DO_MOVE=0; shift;;
    --push-remote) PUSH_REMOTE=1; shift;;
    --no-push-remote) PUSH_REMOTE=0; shift;;
    --rclone-remote) RCLONE_REMOTE="$2"; shift 2;;
    --s3-public-url) S3_PUBLIC_URL="$2"; shift 2;;
    --delete-quarantine-after-push) DELETE_QUAR_AFTER_PUSH=1; shift;;
    --no-update-db-after-push) UPDATE_DB_AFTER_PUSH=0; shift;;
    --update-db-after-push) UPDATE_DB_AFTER_PUSH=1; shift;;
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
  --no-backup                 Skip backup
  --do-move                   Move selected files to quarantine (fixed dir ${HOME_BASE}/quarantine)
  --no-move                   Skip move
  --push-remote               After move, upload quarantine files to remote (RCLONE_REMOTE)
  --no-push-remote            Skip remote upload
  --rclone-remote NAME/PATH   Override RCLONE_REMOTE for this run
  --s3-public-url URL         Override S3_PUBLIC_URL for this run
  --update-db-after-push      Update Messages.mediaUrl to S3 URL after upload (default)
  --no-update-db-after-push   Skip database mediaUrl update after upload
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
DB_UPDATE_CSV="${RUN_DIR}/db_url_update.csv"
DB_UPDATE_SQL="${RUN_DIR}/db_url_update.sql"
DB_UPDATE_LOG="${RUN_DIR}/db_update.log"
PREVIEW_DELETE="${RUN_DIR}/preview_delete_cmds.sh"
PREVIEW_MOVE="${RUN_DIR}/preview_move_cmds.sh"
DO_DELETE_SCRIPT="${RUN_DIR}/do_delete_cmds.sh"
DO_MOVE_SCRIPT="${RUN_DIR}/do_move_cmds.sh"
RCLONE_LIST="${RUN_DIR}/rclone_files_list.txt"

sudo mkdir -p "${HOME_BASE}" "${RUN_DIR}" "${HOME_BASE}/backups" "${QUAR_DIR}"
sudo chown -R "$USER":"$USER" "${HOME_BASE}" || true

if [[ -z "${S3_PUBLIC_URL}" ]]; then
  if [[ "${UPDATE_DB_AFTER_PUSH}" -eq 1 && "${PUSH_REMOTE}" -eq 1 ]]; then
    echo "ERROR: S3_PUBLIC_URL is required when UPDATE_DB_AFTER_PUSH=1 and PUSH_REMOTE=1. Set it in .env_cleanup or pass --s3-public-url."
    exit 1
  fi
  if [[ "${PUSH_REMOTE}" -eq 1 ]]; then
    log "WARN: S3_PUBLIC_URL is empty; database mediaUrl will not be updated."
  fi
fi

log "Run dir: ${RUN_DIR}"
log "Media root: ${MEDIA_ROOT}"
log "Quarantine dir: ${QUAR_DIR}"
log "Backup dir (if used): ${BACKUP_DIR}"
log "Rclone remote in use: ${RCLONE_REMOTE}"
log "Rclone config file: ${RCLONE_CONFIG}"
log "S3 public URL base: ${S3_PUBLIC_URL}"
log "Update DB after push: ${UPDATE_DB_AFTER_PUSH}"

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

# Filter out candidates whose S3 URL would exceed VARCHAR(255)
S3_BASE="${S3_PUBLIC_URL%/}"
if [[ -n "${S3_BASE}" ]]; then
  MAX_REL_LEN=$((255 - ${#S3_BASE} - 1))
  if [[ ${MAX_REL_LEN} -ge 1 ]]; then
    FILTERED_LIST="${RUN_DIR}/media_ticket_candidates_fittable.txt"
    : > "${FILTERED_LIST}"
    while IFS= read -r rel; do
      if [[ ${#rel} -le ${MAX_REL_LEN} ]]; then
        printf '%s\n' "${rel}" >> "${FILTERED_LIST}"
      fi
    done < "${CANDIDATES_LIST}"
    too_long=$(( $(wc -l < "${CANDIDATES_LIST}") - $(wc -l < "${FILTERED_LIST}") ))
    if [[ ${too_long} -gt 0 ]]; then
      log "WARN: ${too_long} candidate(s) exceed VARCHAR(255) S3 URL limit and will be skipped."
      log "Set a shorter S3_PUBLIC_URL or shorten filenames before cleanup."
    fi
    cp "${FILTERED_LIST}" "${CANDIDATES_LIST}"
  fi
fi

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
# Helper: generate CSV of (old_db_url, new_s3_url) for this run
# ---------------------------
generate_db_url_update_csv() {
  local csv_out="$1"
  local s3_base="${S3_PUBLIC_URL%/}" # ensure no trailing slash
  : > "${csv_out}"
  while IFS= read -r rel; do
    [[ -z "${rel}" ]] && continue
    old_url="media/${rel}"
    new_url="${s3_base}/${rel}"
    # Escape double quotes for CSV by doubling them
    old_escaped="${old_url//\"/\"\"}"
    new_escaped="${new_url//\"/\"\"}"
    printf '"%s","%s"\n' "${old_escaped}" "${new_escaped}" >> "${csv_out}"
  done < "${RCLONE_LIST}"
}

# ---------------------------
# Step 10: optionally push to remote via rclone
# ---------------------------
if [[ "${PUSH_REMOTE}" -eq 1 ]]; then
  log "Using rclone remote: ${RCLONE_REMOTE}"
  log "Using S3 public URL base: ${S3_PUBLIC_URL}"
  cp "${CANDIDATES_LIST}" "${RCLONE_LIST}"
  log "Running rclone copy ${QUAR_DIR}/ -> ${RCLONE_REMOTE} using files-from ${RCLONE_LIST}"
  if sudo rclone --config "${RCLONE_CONFIG}" copy "${QUAR_DIR}/" "${RCLONE_REMOTE}" --files-from "${RCLONE_LIST}" --progress --log-file="${RUN_DIR}/rclone_upload.log" --log-level INFO 2>&1 | tee -a "${LOG_FILE}"; then
    log "rclone upload completed successfully. Log: ${RUN_DIR}/rclone_upload.log"

    if [[ "${UPDATE_DB_AFTER_PUSH}" -eq 1 ]]; then
      log "Updating database mediaUrl entries to S3 public URLs..."
      generate_db_url_update_csv "${DB_UPDATE_CSV}"
      log "DB update CSV rows: $(wc -l < "${DB_UPDATE_CSV}" 2>/dev/null || echo 0)"

      {
        echo "CREATE TEMP TABLE s3_media_urls (old_url VARCHAR(255) PRIMARY KEY, new_url VARCHAR(255) NOT NULL);"
        echo "COPY s3_media_urls (old_url, new_url) FROM STDIN WITH (FORMAT csv, DELIMITER ',', QUOTE '\"', HEADER false, NULL '');"
        cat "${DB_UPDATE_CSV}"
        echo "\\."
        echo "UPDATE \"Messages\" m"
        echo "SET \"mediaUrl\" = u.new_url,"
        echo "    \"updatedAt\" = NOW()"
        echo "FROM s3_media_urls u"
        echo "WHERE m.\"mediaUrl\" = u.old_url"
        echo "  AND m.\"ticketId\" IS NOT NULL"
        echo "  AND m.\"mediaUrl\" <> u.new_url;"
        echo "SELECT COUNT(*) AS updated_rows FROM \"Messages\" WHERE \"mediaUrl\" IN (SELECT new_url FROM s3_media_urls);"
      } > "${DB_UPDATE_SQL}"

      if sudo docker exec -i "${DB_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" -At -q -f - < "${DB_UPDATE_SQL}" > "${DB_UPDATE_LOG}" 2>&1; then
        log "Database mediaUrl update completed. See ${DB_UPDATE_LOG}"
        tail -n 5 "${DB_UPDATE_LOG}" 2>/dev/null | while IFS= read -r line; do log "DB: ${line}"; done
      else
        echo "ERROR: database mediaUrl update failed (see ${DB_UPDATE_LOG}). Quarantine files will NOT be deleted so you can retry."
        tail -n 20 "${DB_UPDATE_LOG}" 2>/dev/null || true
        exit 3
      fi
    else
      log "UPDATE_DB_AFTER_PUSH disabled; skipping database mediaUrl rewrite."
    fi

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
    echo "ERROR: rclone upload failed (see ${RUN_DIR}/rclone_upload.log). Quarantine and database NOT modified."
    exit 2
  fi
fi

# ---------------------------
# Step 11: generate restore scripts (backup/quarantine/remote)
# ---------------------------
RESTORE_FROM_BACKUP="${RUN_DIR}/restore_from_backup_${TIMESTAMP}.sh"
RESTORE_FROM_QUAR="${RUN_DIR}/restore_from_quarantine_${TIMESTAMP}.sh"
RESTORE_FROM_REMOTE="${RUN_DIR}/restore_from_remote_${TIMESTAMP}.sh"
RESTORE_DB_URLS="${RUN_DIR}/restore_db_urls_${TIMESTAMP}.sh"

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
  echo "Usage: $0 <rclone_remote> /path/to/run_dir [s3_public_url]"; exit 1
fi
RCLONE_REMOTE="$1"
RUN_DIR="$2"
S3_BASE="${3:-}"
MEDIA_ROOT="/var/lib/docker/volumes/ticketz-docker-acme_backend_public/_data"
DB_CONTAINER="ticketz-docker-acme-postgres-1"
DB_NAME="ticketz"
DB_USER="ticketz"
CSV_FILE="${RUN_DIR}/db_url_update.csv"
if [[ -z "${S3_BASE}" && -f "${CSV_FILE}" ]]; then
  # derive S3_BASE from the first new_url in the CSV (column 2, strip quotes)
  S3_BASE="$(head -n1 "${CSV_FILE}" | awk -F'","' '{print $2}' | sed 's/^"//; s/"$//' | xargs -I {} dirname {} | sed 's|/[^/]*$||')"
fi
if [[ -z "${S3_BASE}" ]]; then
  echo "Error: could not determine S3_BASE. Pass it as third argument or keep db_url_update.csv."; exit 1
fi
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
# Revert mediaUrl from S3 URL back to local media/ path
if [[ -f "${CSV_FILE}" ]]; then
  echo "Reverting database mediaUrl from S3 back to local path..."
  {
    echo "CREATE TEMP TABLE s3_media_urls (old_url VARCHAR(255) PRIMARY KEY, new_url VARCHAR(255) NOT NULL);"
    echo "COPY s3_media_urls (old_url, new_url) FROM STDIN WITH (FORMAT csv, DELIMITER ',', QUOTE '\"', HEADER false, NULL '');"
    cat "${CSV_FILE}"
    echo "\."
    echo "UPDATE \"Messages\" m"
    echo "SET \"mediaUrl\" = u.old_url,"
    echo "    \"updatedAt\" = NOW()"
    echo "FROM s3_media_urls u"
    echo "WHERE m.\"mediaUrl\" = u.new_url"
    echo "  AND m.\"ticketId\" IS NOT NULL"
    echo "  AND m.\"mediaUrl\" <> u.old_url;"
    echo "SELECT COUNT(*) AS reverted_rows FROM \"Messages\" WHERE \"mediaUrl\" IN (SELECT old_url FROM s3_media_urls);"
  } | sudo docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -At -q -f - > "${RUN_DIR}/db_url_restore.log" 2>&1
  echo "Database URL revert completed. Log: ${RUN_DIR}/db_url_restore.log"
else
  echo "WARN: db_url_update.csv not found; database mediaUrl was not reverted."
fi
REST
chmod 644 "${RESTORE_FROM_REMOTE}"

# DB URL rollback script: reverts Messages.mediaUrl from S3 URL back to local media/ path
cat > "${RESTORE_DB_URLS}" <<REST
#!/usr/bin/env bash
set -euo pipefail
if [[ \$# -lt 1 ]]; then
  echo "Usage: \$0 /path/to/run_dir"; exit 1
fi
RUN_DIR="\$1"
MEDIA_ROOT="${MEDIA_ROOT}"
S3_BASE="${S3_PUBLIC_URL%/}"
CSV_FILE="\${RUN_DIR}/db_url_update.csv"
if [[ ! -f "\${CSV_FILE}" ]]; then
  echo "Missing DB URL update CSV: \${CSV_FILE}"; exit 1
fi
{
  echo "CREATE TEMP TABLE s3_media_urls (old_url VARCHAR(255) PRIMARY KEY, new_url VARCHAR(255) NOT NULL);"
  echo "COPY s3_media_urls (old_url, new_url) FROM STDIN WITH (FORMAT csv, DELIMITER ',', QUOTE '\"', HEADER false, NULL '');"
  cat "\${CSV_FILE}"
  echo "\\."
  echo "UPDATE \\"Messages\\" m"
  echo "SET \\"mediaUrl\\" = u.old_url,"
  echo "    \\"updatedAt\\" = NOW()"
  echo "FROM s3_media_urls u"
  echo "WHERE m.\\"mediaUrl\\" = u.new_url"
  echo "  AND m.\\"ticketId\\" IS NOT NULL"
  echo "  AND m.\\"mediaUrl\\" <> u.old_url;"
  echo "SELECT COUNT(*) AS reverted_rows FROM \\"Messages\\" WHERE \\"mediaUrl\\" IN (SELECT old_url FROM s3_media_urls);"
} | sudo docker exec -i ${DB_CONTAINER} psql -U ${DB_USER} -d ${DB_NAME} -At -q -f - > "\${RUN_DIR}/db_url_restore.log" 2>&1
echo "Database URL restore completed. Log: \${RUN_DIR}/db_url_restore.log"
REST
chmod 644 "${RESTORE_DB_URLS}"

log "Generated artifacts in ${RUN_DIR}":
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
log "DB URL rollback script: ${RESTORE_DB_URLS}"
log "Log file: ${LOG_FILE}"
log "Backup dir (if created): ${BACKUP_DIR}"
log "Quarantine dir: ${QUAR_DIR}"
log "Done."
exit 0
