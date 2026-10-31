#!/usr/bin/env bash
set -Eeuo pipefail
# Re-run ZIP installer. Preserve current server_name by reading active nginx config.
NAME=$(awk '$1=="server_name" {gsub(/;/,"",$2); print $2; exit}' /etc/nginx/sites-available/photo-album 2>/dev/null || true)
exec bash /opt/photo-album/scripts/install.sh "${1:-Andrew-Schmidt/Photo-s}" "${2:-${NAME:-_}}"
