#!/usr/bin/env bash
#
# fix_historic_media_urls.sh
#
# Script PONTUAL para atualizar o mediaUrl de arquivos já transferidos para S3
# em execuções anteriores do cleanup_media_manager.sh.
#
# Como usar:
#   1. Gere a lista de arquivos:
#        sudo ./generate_uploaded_files_list.sh
#   2. Execute a correção:
#        sudo ./fix_historic_media_urls.sh
#
# Configurações são lidas de .env_cleanup (mesmo arquivo do cleanup_media_manager.sh).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env_cleanup"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

# ---------------------------
# Configurações (com fallbacks)
# ---------------------------
S3_PUBLIC_URL="${S3_PUBLIC_URL:-}"
DB_CONTAINER="${DB_CONTAINER:-ticketz-docker-acme-postgres-1}"
DB_NAME="${DB_NAME:-ticketz}"
DB_USER="${DB_USER:-ticketz}"

# Arquivo de entrada com paths relativos já enviados ao S3 que cabem em VARCHAR(255).
# O padrão usa all_uploaded_files_fittable.txt, gerado por generate_uploaded_files_list.sh.
INPUT_FILE="${INPUT_FILE:-all_uploaded_files_fittable.txt}"

# ---------------------------
# Caminhos de saída
# ---------------------------
CSV_FILE="${SCRIPT_DIR}/historic_db_url_update.csv"
SQL_FILE="${SCRIPT_DIR}/historic_db_url_update.sql"
LOG_FILE="${SCRIPT_DIR}/historic_db_update.log"

if [[ -z "${S3_PUBLIC_URL}" ]]; then
  echo "ERROR: S3_PUBLIC_URL não está definida. Configure-a no .env_cleanup ou exporte antes de executar."
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/${INPUT_FILE}" ]]; then
  echo "ERROR: Arquivo de entrada não encontrado: ${SCRIPT_DIR}/${INPUT_FILE}"
  echo "Gere-o executando: sudo ./generate_uploaded_files_list.sh"
  exit 1
fi

S3_BASE="${S3_PUBLIC_URL%/}"
MAX_REL_LEN=$((255 - ${#S3_BASE} - 1))

log() { echo "[$(date +'%F %T')] $*"; }

log "S3_PUBLIC_URL: ${S3_PUBLIC_URL}"
log "Max rel path length for VARCHAR(255): ${MAX_REL_LEN}"

log "Gerando CSV de correção histórica..."
: > "${CSV_FILE}"
while IFS= read -r rel; do
  [[ -z "${rel}" ]] && continue
  if [[ ${#rel} -gt ${MAX_REL_LEN} ]]; then
    log "SKIP (too long for VARCHAR(255)): ${rel}"
    continue
  fi
  old_url="media/${rel}"
  new_url="${S3_BASE}/${rel}"
  old_escaped="${old_url//\"/\"\"}"
  new_escaped="${new_url//\"/\"\"}"
  printf '"%s","%s"\n' "${old_escaped}" "${new_escaped}" >> "${CSV_FILE}"
done < "${SCRIPT_DIR}/${INPUT_FILE}"

log "CSV gerado: ${CSV_FILE}"
log "Total de linhas: $(wc -l < "${CSV_FILE}" 2>/dev/null || echo 0)"

log "Gerando SQL..."
{
  echo "CREATE TEMP TABLE s3_media_urls (old_url VARCHAR(255) PRIMARY KEY, new_url VARCHAR(255) NOT NULL);"
  echo "COPY s3_media_urls (old_url, new_url) FROM STDIN WITH (FORMAT csv, DELIMITER ',', QUOTE '\"', HEADER false, NULL '');"
  cat "${CSV_FILE}"
  echo "\\."
  echo "UPDATE \"Messages\" m"
  echo "SET \"mediaUrl\" = u.new_url,"
  echo "    \"updatedAt\" = NOW()"
  echo "FROM s3_media_urls u"
  echo "WHERE m.\"mediaUrl\" = u.old_url"
  echo "  AND m.\"ticketId\" IS NOT NULL"
  echo "  AND m.\"mediaUrl\" <> u.new_url;"
  echo "SELECT COUNT(*) AS rows_to_update FROM s3_media_urls;"
  echo "SELECT COUNT(*) AS updated_rows FROM \"Messages\" WHERE \"mediaUrl\" IN (SELECT new_url FROM s3_media_urls);"
} > "${SQL_FILE}"

log "Executando UPDATE no banco de dados..."
if sudo docker exec -i "${DB_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" -At -q -f - < "${SQL_FILE}" > "${LOG_FILE}" 2>&1; then
  log "UPDATE concluído com sucesso."
  log "Veja o log em: ${LOG_FILE}"
  tail -n 10 "${LOG_FILE}" | while IFS= read -r line; do log "DB: ${line}"; done
else
  echo "ERROR: Falha ao executar UPDATE no banco."
  tail -n 20 "${LOG_FILE}" 2>/dev/null || true
  exit 2
fi
