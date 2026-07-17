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
FITTABLE_FILE="${SCRIPT_DIR}/all_uploaded_files_fittable.txt"
TOO_LONG_FILE="${SCRIPT_DIR}/all_uploaded_files_too_long.txt"

S3_PUBLIC_URL="${S3_PUBLIC_URL:-}"
S3_BASE="${S3_PUBLIC_URL%/}"
# mediaUrl column is VARCHAR(255). The S3 URL is: S3_BASE + "/" + rel_path
# Therefore the max rel_path length is: 255 - len(S3_BASE) - 1
if [[ -z "${S3_BASE}" ]]; then
  echo "ERROR: S3_PUBLIC_URL não está definida. Configure-a no .env_cleanup."
  exit 1
fi
MAX_REL_LEN=$((255 - ${#S3_BASE} - 1))
if [[ ${MAX_REL_LEN} -lt 1 ]]; then
  echo "ERROR: S3_PUBLIC_URL muito longa; não há espaço para paths relativos."
  exit 1
fi

if [[ ! -d "${RUNS_DIR}" ]]; then
  echo "ERROR: Diretório de runs não encontrado: ${RUNS_DIR}"
  exit 1
fi

: > "${OUTPUT_FILE}"
: > "${FITTABLE_FILE}"
: > "${TOO_LONG_FILE}"

find "${RUNS_DIR}" -mindepth 2 -maxdepth 2 -type f -name 'rclone_files_list.txt' -print0 | while IFS= read -r -d '' file; do
  cat "${file}"
done | sed '/^$/d' | sort -u > "${OUTPUT_FILE}"

while IFS= read -r rel; do
  [[ -z "${rel}" ]] && continue
  if [[ ${#rel} -le ${MAX_REL_LEN} ]]; then
    printf '%s\n' "${rel}" >> "${FITTABLE_FILE}"
  else
    printf '%s\n' "${rel}" >> "${TOO_LONG_FILE}"
  fi
done < "${OUTPUT_FILE}"

echo "S3_PUBLIC_URL: ${S3_PUBLIC_URL}"
echo "Máximo de caracteres para path relativo: ${MAX_REL_LEN}"
echo "Gerado: ${OUTPUT_FILE}"
echo "  Total de arquivos únicos: $(wc -l < "${OUTPUT_FILE}" 2>/dev/null || echo 0)"
echo "Gerado: ${FITTABLE_FILE}"
echo "  Cabem no VARCHAR(255): $(wc -l < "${FITTABLE_FILE}" 2>/dev/null || echo 0)"
echo "Gerado: ${TOO_LONG_FILE}"
echo "  Excedem VARCHAR(255): $(wc -l < "${TOO_LONG_FILE}" 2>/dev/null || echo 0)"
