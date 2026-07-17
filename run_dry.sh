#!/usr/bin/env bash
# run_dry.sh - wrapper to run cleanup_media_manager.sh as a dry run even if defaults enable actions.
# Usage:
#   sudo ./run_dry.sh --days 5    # runs dry-run regardless of defaults
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/cleanup_media_manager.sh"
if [[ ! -f "${SCRIPT}" ]]; then
  echo "Script not found: ${SCRIPT}"
  exit 1
fi
# Forward all args to main script, forcing no actions for this run.
sudo "${SCRIPT}" \
  --no-backup \
  --no-move \
  --no-push-remote \
  --no-update-db-after-push \
  "$@"
