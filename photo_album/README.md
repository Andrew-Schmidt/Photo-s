# Photo Albums

A small, self-hosted private photo album web app for Ubuntu EC2. Separate from the Inventory System: no inventory, grading, pricing, or intake sessions.

## Features

- Password-protected private gallery
- Create, rename, describe, and delete albums
- Upload multiple JPG, PNG, WebP, and GIF files at once
- Take a photo directly from a phone browser using the camera capture input (device/browser support varies)
- Add comma-separated tags during upload/capture; edit tags per photo and filter within an album
- Automatically generated image thumbnails
- Captions and moving photos between albums
- Download an original photo or a whole album as ZIP
- Responsive layout for desktop and mobile
- Flask, SQLite, Pillow, Gunicorn, and Nginx; no external databases or cloud APIs required

**Camera notes:** On compatible mobile browsers, **Take a picture** prompts the device camera (rear-facing when supported); on other devices it may open a file picker. Take one picture, save, and repeat. Use HTTPS on EC2. Tags are saved to each photo in SQLite, not embedded into the original image. Existing installations gain the `tags` column automatically without deleting photos.

**Limitations:** One shared administrator password, not multiple users. GIF thumbnails are static. Photos retain their original files and orientation metadata; thumbnails are auto-rotated. Large ZIPs are assembled in memory. Intended for modest personal collections, not a public photo-sharing site. Upload size limit is **40 MB per request**, so split large batches or adjust both Nginx and the app settings.

## Deploy from GitHub to a NEW Ubuntu EC2 instance

1. Download/extract this package on your computer, create a **new** GitHub repository, and commit/push its contents (do not push your personal photos or `.env` files). Use a separate repo from your existing Inventory System.
2. On AWS, launch **Ubuntu 24.04 LTS** EC2, attach persistent EBS storage with enough space for photos, and assign an Elastic IP if you want a stable public address. Security group: allow SSH 22 **only from your IP**, and web ports 80/443 from intended users. Do not expose port 8010.
3. SSH to the new instance. Download the install script from your repo. Substitute your own values:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/scripts/install.sh -o install.sh
   sudo bash install.sh https://github.com/YOUR_USERNAME/YOUR_REPO.git photos.example.com
   ```

   You can use your public IP address instead of `photos.example.com` while testing, or omit the second argument. The script asks for a **12+ character password**. On first setup, run it from an interactive SSH terminal. A private repo requires GitHub SSH deploy-key authentication (or another secure Git credential) configured for the clone first.

4. Test with `http://YOUR_EC2_IP`. **Don't upload personal photos over plain HTTP.** Set your DNS A record to the EC2 Elastic IP and secure it with Let's Encrypt:

   ```bash
   sudo apt-get install -y certbot python3-certbot-nginx
   sudo certbot --nginx -d photos.example.com
   sudo sed -i 's/^COOKIE_SECURE=0$/COOKIE_SECURE=1/' /etc/photo-album.env
   sudo systemctl restart photo-album
   ```

   Make sure DNS points to the instance and inbound 80/443 are open before Certbot. For a deployment reachable only through Tailscale, use a suitable HTTPS option for that environment instead.

## Update from GitHub latest branch ZIP

On the server:

```bash
sudo bash /opt/photo-album/scripts/update.sh
```

Uploads and the SQLite database are stored **outside the Git checkout** in `/var/lib/photo-album`, so ZIP updates do not replace or delete them.

## Backup

Backup `/var/lib/photo-album/` regularly, including `albums.db`, `originals/`, and `thumbnails/`. For a consistent snapshot, stop the app before copying:

```bash
sudo systemctl stop photo-album
sudo tar -C /var/lib -czf "$HOME/photo-album-backup-$(date +%F).tar.gz" photo-album
sudo systemctl start photo-album
```

Keep backups off-instance (separate EBS snapshots or a private S3 bucket). **Deleting an album deletes all its associated original photo files.**

## Troubleshooting

```bash
sudo systemctl status photo-album --no-pager
sudo journalctl -u photo-album -n 100 --no-pager
sudo nginx -t
```

`/etc/photo-album.env` stores the password hash, server secret, and application settings. It is created only on initial installation and has root-only permissions. When you change `MAX_UPLOAD_MB`, also update `client_max_body_size` in `/etc/nginx/sites-available/photo-album`; reload Nginx.

## Run locally for development

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export SECRET_KEY="$(python -c 'import secrets;print(secrets.token_hex(32))')"
export ALBUM_PASSWORD_HASH="$(python -c 'from werkzeug.security import generate_password_hash;print(generate_password_hash("replace-this-password"))')"
flask --app app run --debug
```

Use `http://127.0.0.1:5000`. Debug mode is for **local testing only**, not deployment.
