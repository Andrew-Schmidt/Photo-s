#!/usr/bin/env bash
set -Eeuo pipefail

# Run on a fresh Ubuntu 24.04/22.04 EC2 instance:
# sudo bash install.sh https://github.com/USERNAME/REPOSITORY.git [domain-or-server-ip]

REPO_URL="${1:-}"
SERVER_NAME="${2:-_}"
INSTALL_DIR=/opt/photo-album
DATA_DIR=/var/lib/photo-album
ENV_FILE=/etc/photo-album.env
APP_USER=photoalbum

if [[ $EUID -ne 0 ]]; then echo 'Run this script using sudo.' >&2; exit 1; fi
if [[ -z "$REPO_URL" ]]; then echo 'Usage: sudo bash install.sh GIT_REPO_URL [domain-or-ip]' >&2; exit 1; fi
if [[ "$SERVER_NAME" != _ && ! "$SERVER_NAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then echo 'Invalid domain or IP' >&2; exit 1; fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip git nginx openssl ca-certificates
if ! id "$APP_USER" &>/dev/null; then useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin "$APP_USER"; fi
mkdir -p "$INSTALL_DIR" "$DATA_DIR"/{originals,thumbnails}

# Public HTTPS repositories work immediately. Private repositories require a deploy key
# or GitHub credential accessible to root before running this installer.
if [[ -e "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  if [[ -n "$(ls -A "$INSTALL_DIR")" ]]; then echo "$INSTALL_DIR is not empty" >&2; exit 1; fi
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ ! -t 0 ]]; then echo 'Interactive terminal required on first install to set album password.' >&2; exit 1; fi
  while true; do
    read -rs -p 'Choose album password (minimum 12 characters): ' PASSWORD; echo
    if [[ ${#PASSWORD} -ge 12 ]]; then break; fi
    echo 'Password is too short.'
  done
  export ALBUM_SETUP_PASSWORD="$PASSWORD"
  PASSHASH=$("$INSTALL_DIR/.venv/bin/python" -c 'from werkzeug.security import generate_password_hash; import os; print(generate_password_hash(os.environ["ALBUM_SETUP_PASSWORD"]))')
  unset PASSWORD ALBUM_SETUP_PASSWORD
  SECRET=$(openssl rand -hex 32)
  printf 'SECRET_KEY=%s\nALBUM_PASSWORD_HASH=%s\nALBUM_DATA_DIR=%s\nMAX_UPLOAD_MB=40\nCOOKIE_SECURE=0\n' "$SECRET" "$PASSHASH" "$DATA_DIR" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi
chown -R "$APP_USER:$APP_USER" "$DATA_DIR"
chown -R root:root "$INSTALL_DIR"
chmod 755 "$DATA_DIR" "$INSTALL_DIR"
cat > /etc/systemd/system/photo-album.service <<EOF
[Unit]
Description=Photo Album Web App
After=network.target
[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$INSTALL_DIR/.venv/bin/gunicorn --workers 2 --bind 127.0.0.1:8010 --timeout 120 app:app
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/nginx/sites-available/photo-album <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;
    client_max_body_size 40m;
    location / {
        proxy_pass http://127.0.0.1:8010;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
EOF
ln -sfn /etc/nginx/sites-available/photo-album /etc/nginx/sites-enabled/photo-album
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl daemon-reload
systemctl enable --now photo-album.service
systemctl enable --now nginx
systemctl reload nginx
printf '\nInstallation finished. Open http://%s/ (or your EC2 public IP).\n' "$SERVER_NAME"
printf 'IMPORTANT: Enable HTTPS before uploading private photos. Read README.md.\n'
printf 'Photos and SQLite database: %s\n' "$DATA_DIR"
