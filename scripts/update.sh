#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $EUID -ne 0 ]]; then echo 'Run with sudo.' >&2; exit 1; fi
cd /opt/photo-album
git pull --ff-only
.venv/bin/pip install -r requirements.txt
systemctl restart photo-album
systemctl --no-pager status photo-album
