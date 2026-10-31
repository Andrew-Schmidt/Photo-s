# Photo Albums — ZIP-based GitHub deployment

This package includes the Photo Albums v2 application (mobile **Take a picture**, tags, albums and downloads) and an **install.sh** at the ZIP root.

The installer **always downloads the latest ZIP of the GitHub `main` branch** of `Andrew-Schmidt/Photo-s`. It does NOT download a random uploaded ZIP or GitHub release asset, and does not use `git pull`. The `main` branch must contain the updated Photo Albums source code, including the camera and tags features. The bundled `photo_album/` folder is provided for uploading to GitHub; the installer downloads from GitHub rather than using that local copy.

## First: upload the updated source to GitHub

Unzip this package. Upload the **contents of the `photo_album` folder** (not the top-level folder itself) to https://github.com/Andrew-Schmidt/Photo-s on `main`, replacing existing files. Commit the changes. Verify GitHub shows `templates/album.html` with a **Take a picture** control.

## Fresh install OR update on existing Ubuntu EC2

Copy the ZIP's **root** `install.sh` to the server (or download it from this ZIP after uploading), then run:

```bash
sudo bash install.sh Andrew-Schmidt/Photo-s
```

If using a domain, provide it on first install:

```bash
sudo bash install.sh Andrew-Schmidt/Photo-s photos.example.com
```

To update again later:

```bash
sudo bash /opt/photo-album/scripts/update.sh
```

This uses the latest `main` ZIP each time and preserves `/var/lib/photo-album/` (database, originals, thumbnails) and `/etc/photo-album.env` (password and secret). The legacy `.git` directory is left intact but is no longer used to update. To verify the UI code on the instance:

```bash
sudo grep -ni 'take a picture' /opt/photo-album/templates/album.html
sudo grep -ni 'tags' /opt/photo-album/templates/album.html
sudo systemctl status photo-album --no-pager
```

**Important:** Public GitHub repo required for this direct ZIP URL. Your EC2 machine needs outbound HTTPS; security group needs inbound 80 and (for HTTPS) 443. Set up TLS before uploading private photos, and set `COOKIE_SECURE=1` in `/etc/photo-album.env` after HTTPS is configured. `install.sh` writes Nginx HTTP config, so if you already use Certbot custom configuration, back up `/etc/nginx/sites-available/photo-album` and reapply HTTPS config after running the installer.

See `photo_album/README.md` for backup and full application notes.
