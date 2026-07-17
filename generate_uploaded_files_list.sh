#!/usr/bin/env bash
#
# generate_uploaded_files_list.sh
#
# Gera o arquivo all_uploaded_files.txt a partir dos rclone_files_list.txt
# de todos os runs existentes na pasta de execução do cleanup_media_manager.sh.
#
# Uso:
#   sudo ./generate_uploaded_files_list.sh
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

HOME_BASE="${HOME_BASE:-/home/ubuntu/cleanup}"
RUNS_DIR="${HOME_BASE}/runs"
OUTPUT_FILE="${SCRIPT_DIR}/all_uploaded_files.txt"

if [[ ! -d "${RUNS_DIR}" ]]; then
  echo "ERROR: Diretório de runs não encontrado: ${RUNS_DIR}"
  exit 1
fi

: > "${OUTPUT_FILE}"

find "${RUNS_DIR}" -mindepth 2 -maxdepth 2 -type f -name 'rclone_files_list.txt' -print0 | while IFS= read -r -d '' file; do
  cat "${file}"
done | sed '/^$/d' | sort -u > "${OUTPUT_FILE}"

echo "Gerado: ${OUTPUT_FILE}"
echo "Total de arquivos únicos: $(wc -l < "${OUTPUT_FILE}" 2>/dev/null || echo 0)"
