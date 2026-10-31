#!/usr/bin/env bash
set -Eeuo pipefail
# Ubuntu EC2. Downloads latest GitHub main-branch ZIP on every run.
REPO="${1:-Andrew-Schmidt/Photo-s}"
SERVER_NAME="${2:-_}"
BRANCH="${PHOTO_ALBUM_BRANCH:-main}"
INSTALL_DIR=/opt/photo-album
DATA_DIR=/var/lib/photo-album
ENV_FILE=/etc/photo-album.env
APP_USER=photoalbum

if [[ $EUID -ne 0 ]]; then echo 'Run with sudo.' >&2; exit 1; fi
# Accept org/repo or standard public GitHub URL.
REPO="${REPO#https://github.com/}"; REPO="${REPO#http://github.com/}"; REPO="${REPO%.git}"; REPO="${REPO%/}"
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo 'Usage: sudo bash install.sh [GitHubOwner/Repo] [domain-or-IP]' >&2; exit 1
fi
if [[ "$SERVER_NAME" != _ && ! "$SERVER_NAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then echo 'Invalid hostname.' >&2; exit 1; fi
if [[ ! "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]; then echo 'Invalid branch.' >&2; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl unzip rsync python3 python3-venv python3-pip nginx openssl
if ! id "$APP_USER" &>/dev/null; then useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin "$APP_USER"; fi
mkdir -p "$DATA_DIR"/{originals,thumbnails} "$INSTALL_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ZIP_URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.zip"
echo "Downloading latest branch ZIP from $ZIP_URL"
curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 "$ZIP_URL" -o "$TMP/source.zip"
unzip -q "$TMP/source.zip" -d "$TMP/extracted"
# GitHub archives contain a single top-level directory.
mapfile -t folders < <(find "$TMP/extracted" -mindepth 1 -maxdepth 1 -type d)
if (( ${#folders[@]} != 1 )); then echo 'Unexpected source ZIP structure.' >&2; exit 1; fi
SRC="${folders[0]}"
for f in app.py requirements.txt templates/album.html; do
  if [[ ! -f "$SRC/$f" ]]; then echo "Missing $f in GitHub ZIP; not updating app." >&2; exit 1; fi
done
# Preserve current application code as a rollback copy, excluding venv and Git internals.
BACKUP="$TMP/previous"
mkdir -p "$BACKUP"
rsync -a --exclude=.venv --exclude=.git "$INSTALL_DIR/" "$BACKUP/"
# New files replace old files; python environment and existing .git folder are left undisturbed.
# .git remains for historical reference only; updates use GitHub ZIP, never git pull.
rsync -a --delete --exclude=.venv --exclude=.git --exclude=data "$SRC/" "$INSTALL_DIR/"
if [[ ! -x "$INSTALL_DIR/.venv/bin/python" ]]; then python3 -m venv "$INSTALL_DIR/.venv"; fi
if ! "$INSTALL_DIR/.venv/bin/python" -m pip install -r "$INSTALL_DIR/requirements.txt"; then
  echo 'Dependency install failed; restoring previous code.' >&2
  rsync -a --delete --exclude=.venv --exclude=.git --exclude=data "$BACKUP/" "$INSTALL_DIR/"
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ ! -t 0 ]]; then echo 'First install requires an interactive terminal to set a password.' >&2; exit 1; fi
  while true; do
    read -rs -p 'Choose album password (at least 12 characters): ' PASSWORD; echo
    [[ ${#PASSWORD} -ge 12 ]] && break
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
systemctl restart photo-album.service
systemctl enable --now nginx
systemctl reload nginx
printf '\nInstalled latest %s/%s from GitHub.\n' "$REPO" "$BRANCH"
printf 'App: /opt/photo-album | Photos and DB: %s | Credentials: %s\n' "$DATA_DIR" "$ENV_FILE"
printf 'Visit http://%s (or the EC2 IP). Enable HTTPS before uploading private images.\n' "$SERVER_NAME"
