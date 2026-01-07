#!/usr/bin/env bash
# run_dry.sh - wrapper to run cleanup_media_manager.sh as a dry run even if defaults enable actions.
# Usage:
#   sudo ./run_dry.sh --days 5    # runs dry-run regardless of defaults
#
SCRIPT="/home/ubuntu/cleanup/cleanup_media_manager.sh"
if [[ ! -f "${SCRIPT}" ]]; then
  echo "Script not found: ${SCRIPT}"
  exit 1
fi
# Export flags to force no actions for this run
export DO_BACKUP=0
export DO_MOVE=0
export PUSH_REMOTE=0
# forward all args to main script
sudo env DO_BACKUP=0 DO_MOVE=0 PUSH_REMOTE=0 "${SCRIPT}" "$@"
