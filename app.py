import io
import os
import re
import secrets
import sqlite3
import uuid
import zipfile
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path

from flask import Flask, abort, flash, redirect, render_template, request, send_file, send_from_directory, session, url_for
from PIL import Image, ImageOps, UnidentifiedImageError
from werkzeug.security import check_password_hash, generate_password_hash
from werkzeug.utils import secure_filename

BASE = Path(__file__).resolve().parent
DATA = Path(os.environ.get('ALBUM_DATA_DIR', BASE / 'data')).resolve()
UPLOADS = DATA / 'originals'
THUMBS = DATA / 'thumbnails'
for path in (DATA, UPLOADS, THUMBS):
    path.mkdir(parents=True, exist_ok=True)

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', '')
if not app.secret_key:
    raise RuntimeError('SECRET_KEY must be set in environment')
app.config['MAX_CONTENT_LENGTH'] = int(os.environ.get('MAX_UPLOAD_MB', '40')) * 1024 * 1024
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
app.config['SESSION_COOKIE_SECURE'] = os.environ.get('COOKIE_SECURE', '0') == '1'


def connection():
    db = sqlite3.connect(DATA / 'albums.db', timeout=30)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA foreign_keys = ON')
    return db


def initialize():
    with connection() as db:
        db.execute('CREATE TABLE IF NOT EXISTS albums (id INTEGER PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT "", created_at TEXT NOT NULL)')
        db.execute('''CREATE TABLE IF NOT EXISTS photos (
            id INTEGER PRIMARY KEY, album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
            filename TEXT NOT NULL, stored_name TEXT NOT NULL UNIQUE, caption TEXT NOT NULL DEFAULT '',
            uploaded_at TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL)''')
        db.execute('CREATE INDEX IF NOT EXISTS idx_photo_album ON photos(album_id, id DESC)')

initialize()


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return fn(*args, **kwargs)
    return wrapper


@app.context_processor
def inject_token():
    if 'csrf' not in session:
        session['csrf'] = secrets.token_urlsafe(32)
    return {'csrf_token': session['csrf']}


@app.before_request
def check_csrf():
    if request.method == 'POST' and request.endpoint != 'login':
        if not secrets.compare_digest(session.get('csrf', ''), request.form.get('csrf_token', '')):
            abort(400, 'Invalid form token; refresh and retry')


@app.route('/login', methods=['GET', 'POST'])
def login():
    if session.get('logged_in'):
        return redirect(url_for('index'))
    if request.method == 'POST':
        expected = os.environ.get('ALBUM_PASSWORD_HASH', '')
        if expected and check_password_hash(expected, request.form.get('password', '')):
            session.clear()
            session['logged_in'] = True
            session['csrf'] = secrets.token_urlsafe(32)
            return redirect(url_for('index'))
        flash('Incorrect password.', 'error')
    return render_template('login.html')


@app.post('/logout')
@login_required
def logout():
    session.clear()
    return redirect(url_for('login'))


@app.get('/')
@login_required
def index():
    with connection() as db:
        albums = db.execute('''SELECT a.*, COUNT(p.id) AS count,
            (SELECT stored_name FROM photos WHERE album_id=a.id ORDER BY id DESC LIMIT 1) AS cover
            FROM albums a LEFT JOIN photos p ON p.album_id=a.id GROUP BY a.id ORDER BY a.id DESC''').fetchall()
    return render_template('index.html', albums=albums)


@app.post('/albums')
@login_required
def create_album():
    name = request.form.get('name', '').strip()[:100]
    description = request.form.get('description', '').strip()[:500]
    if not name:
        flash('Give your album a name.', 'error')
        return redirect(url_for('index'))
    with connection() as db:
        cursor = db.execute('INSERT INTO albums(name,description,created_at) VALUES(?,?,?)', (name, description, datetime.now(timezone.utc).isoformat()))
        id_ = cursor.lastrowid
    return redirect(url_for('album', album_id=id_))


def get_album(db, album_id):
    row = db.execute('SELECT * FROM albums WHERE id=?', (album_id,)).fetchone()
    if row is None:
        abort(404)
    return row


@app.get('/albums/<int:album_id>')
@login_required
def album(album_id):
    with connection() as db:
        record = get_album(db, album_id)
        photos = db.execute('SELECT * FROM photos WHERE album_id=? ORDER BY id DESC', (album_id,)).fetchall()
        all_albums = db.execute('SELECT id,name FROM albums ORDER BY name').fetchall()
    return render_template('album.html', album=record, photos=photos, all_albums=all_albums)


@app.post('/albums/<int:album_id>/edit')
@login_required
def edit_album(album_id):
    name = request.form.get('name', '').strip()[:100]
    if not name:
        abort(400)
    with connection() as db:
        get_album(db, album_id)
        db.execute('UPDATE albums SET name=?,description=? WHERE id=?', (name, request.form.get('description','').strip()[:500], album_id))
    return redirect(url_for('album', album_id=album_id))


@app.post('/albums/<int:album_id>/delete')
@login_required
def delete_album(album_id):
    with connection() as db:
        get_album(db, album_id)
        photos = db.execute('SELECT stored_name FROM photos WHERE album_id=?', (album_id,)).fetchall()
        db.execute('DELETE FROM albums WHERE id=?', (album_id,))
    for p in photos:
        (UPLOADS / p['stored_name']).unlink(missing_ok=True)
        (THUMBS / (p['stored_name'] + '.jpg')).unlink(missing_ok=True)
    return redirect(url_for('index'))


@app.post('/albums/<int:album_id>/upload')
@login_required
def upload(album_id):
    with connection() as db:
        get_album(db, album_id)
    accepted = 0
    rejected = 0
    for file in request.files.getlist('photos'):
        if not file.filename:
            continue
        original = secure_filename(file.filename)[:180] or 'photo'
        extension = Path(original).suffix.lower()
        if extension not in ('.jpg', '.jpeg', '.png', '.webp', '.gif'):
            rejected += 1
            continue
        name = f'{uuid.uuid4().hex}{extension}'
        target = UPLOADS / name
        try:
            file.save(target)
            with Image.open(target) as im:
                im.verify()
            with Image.open(target) as im:
                if im.width * im.height > 100_000_000:
                    raise ValueError('Image too large')
                width, height = im.size
                preview = ImageOps.exif_transpose(im)
                preview.thumbnail((850, 850))
                if preview.mode != 'RGB':
                    preview = preview.convert('RGB')
                preview.save(THUMBS / (name + '.jpg'), 'JPEG', quality=82, optimize=True)
            with connection() as db:
                db.execute('INSERT INTO photos(album_id,filename,stored_name,uploaded_at,width,height) VALUES(?,?,?,?,?,?)',
                           (album_id, original, name, datetime.now(timezone.utc).isoformat(), width, height))
            accepted += 1
        except (UnidentifiedImageError, OSError, ValueError):
            target.unlink(missing_ok=True)
            (THUMBS / (name + '.jpg')).unlink(missing_ok=True)
            rejected += 1
    flash(f'Added {accepted} photo(s).' + (f' Skipped {rejected} unsupported or invalid file(s).' if rejected else ''))
    return redirect(url_for('album', album_id=album_id))


def photo_by_id(db, photo_id):
    p = db.execute('SELECT * FROM photos WHERE id=?', (photo_id,)).fetchone()
    if p is None:
        abort(404)
    return p


@app.get('/photos/<int:photo_id>/<string:kind>')
@login_required
def serve_photo(photo_id, kind):
    with connection() as db:
        p = photo_by_id(db, photo_id)
    if kind == 'thumbnail':
        return send_from_directory(THUMBS, p['stored_name'] + '.jpg', mimetype='image/jpeg')
    if kind == 'view':
        return send_from_directory(UPLOADS, p['stored_name'])
    if kind == 'download':
        return send_from_directory(UPLOADS, p['stored_name'], as_attachment=True, download_name=p['filename'])
    abort(404)


@app.post('/photos/<int:photo_id>/edit')
@login_required
def edit_photo(photo_id):
    with connection() as db:
        p = photo_by_id(db, photo_id)
        target = request.form.get('album_id', type=int, default=p['album_id'])
        get_album(db, target)
        db.execute('UPDATE photos SET caption=?,album_id=? WHERE id=?', (request.form.get('caption','').strip()[:250], target, photo_id))
    return redirect(url_for('album', album_id=target))


@app.post('/photos/<int:photo_id>/delete')
@login_required
def delete_photo(photo_id):
    with connection() as db:
        p = photo_by_id(db, photo_id)
        db.execute('DELETE FROM photos WHERE id=?', (photo_id,))
    (UPLOADS / p['stored_name']).unlink(missing_ok=True)
    (THUMBS / (p['stored_name'] + '.jpg')).unlink(missing_ok=True)
    return redirect(url_for('album', album_id=p['album_id']))


@app.get('/albums/<int:album_id>/download')
@login_required
def download_album(album_id):
    with connection() as db:
        a = get_album(db, album_id)
        photos = db.execute('SELECT * FROM photos WHERE album_id=?', (album_id,)).fetchall()
    if not photos:
        flash('This album is empty.', 'error')
        return redirect(url_for('album', album_id=album_id))
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_STORED) as archive:
        for p in photos:
            source = UPLOADS / p['stored_name']
            if source.is_file():
                archive.write(source, arcname=f"{p['id']}_{p['filename']}")
    buffer.seek(0)
    return send_file(buffer, mimetype='application/zip', as_attachment=True, download_name=f"{secure_filename(a['name']) or 'album'}.zip")


@app.errorhandler(413)
def too_large(_):
    return 'Upload too large. Reduce image size or raise MAX_UPLOAD_MB.', 413


@app.get('/health')
def health():
    return {'status': 'ok'}

@app.get('/albums/<int:album_id>/cover')
@login_required
def album_cover(album_id):
    with connection() as db:
        get_album(db, album_id)
        p = db.execute('SELECT stored_name FROM photos WHERE album_id=? ORDER BY id DESC LIMIT 1', (album_id,)).fetchone()
    if not p:
        abort(404)
    return send_from_directory(THUMBS, p['stored_name'] + '.jpg', mimetype='image/jpeg')
