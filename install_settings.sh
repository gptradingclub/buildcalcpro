#!/bin/bash
set -e

echo "=== Installing Custom Branding Backend ==="
echo ""

# 1. Backup server.py
sudo cp /var/www/buildcalcpro/server.py /var/www/buildcalcpro/server.py.PRE_SETTINGS
echo "✓ Backup: server.py.PRE_SETTINGS"

# 2. Create logos directory
sudo mkdir -p /var/www/buildcalcpro/logos
sudo chown www-data:www-data /var/www/buildcalcpro/logos
sudo chmod 755 /var/www/buildcalcpro/logos
echo "✓ Logos directory created: /var/www/buildcalcpro/logos"

# 3. Install Pillow for image validation (if not present)
if ! python3 -c "from PIL import Image" 2>/dev/null; then
    echo "Installing Pillow for image validation..."
    sudo pip3 install Pillow --break-system-packages --quiet
fi
echo "✓ Pillow installed (image validation)"

# 4. Add new endpoints to server.py
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/server.py', 'r') as f:
    content = f.read()

# Check if endpoints already exist
if '/api/settings' in content:
    print('ALREADY: Settings endpoints already exist, skipping')
    import sys
    sys.exit(0)

# Add imports at the top if needed
import_addition = '''
import uuid
from werkzeug.utils import secure_filename
try:
    from PIL import Image
    PIL_AVAILABLE = True
except ImportError:
    PIL_AVAILABLE = False

LOGOS_DIR = Path("/var/www/buildcalcpro/logos")
ALLOWED_IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp"}
MAX_LOGO_SIZE = 2 * 1024 * 1024  # 2 MB

'''

# Insert after the existing imports - find a marker
marker = 'try:\n    from anthropic import Anthropic'
if marker in content:
    content = content.replace(marker, import_addition + marker, 1)
    print('OK: Imports added')
else:
    print('WARN: Could not find import marker')

# Now add the endpoints - insert BEFORE the MAIN marker
endpoints = '''

# ─────────────────────────────────────────────────────────────
# SETTINGS / CUSTOM BRANDING (auth + subscription required)
# ─────────────────────────────────────────────────────────────

@app.route("/api/settings", methods=["GET", "OPTIONS"])
@auth_required()
def get_settings():
    if request.method == "OPTIONS":
        return "", 204

    user = request.current_user
    return jsonify({
        "ok": True,
        "company_name": user.get("company_name") or "",
        "company_logo": user.get("company_logo") or "",
        "company_phone": user.get("company_phone") or "",
        "company_email": user.get("company_email") or "",
        "company_address": user.get("company_address") or "",
        "company_website": user.get("company_website") or "",
        "company_license": user.get("company_license") or "",
    })


@app.route("/api/settings", methods=["POST", "OPTIONS"])
@auth_required()
def update_settings():
    if request.method == "OPTIONS":
        return "", 204

    data = request.get_json(force=True, silent=True) or {}
    user_id = request.current_user["id"]

    # Sanitize inputs - all strings, limit length
    def clean(val, max_len=255):
        if val is None:
            return ""
        s = str(val).strip()[:max_len]
        return s

    fields = {
        "company_name": clean(data.get("company_name"), 100),
        "company_phone": clean(data.get("company_phone"), 30),
        "company_email": clean(data.get("company_email"), 100),
        "company_address": clean(data.get("company_address"), 200),
        "company_website": clean(data.get("company_website"), 200),
        "company_license": clean(data.get("company_license"), 50),
    }

    with get_db() as conn:
        conn.execute(
            """UPDATE users SET
                company_name = ?,
                company_phone = ?,
                company_email = ?,
                company_address = ?,
                company_website = ?,
                company_license = ?
               WHERE id = ?""",
            (fields["company_name"], fields["company_phone"], fields["company_email"],
             fields["company_address"], fields["company_website"], fields["company_license"],
             user_id),
        )

    log.info(f"settings updated for user_id={user_id}")
    return jsonify({"ok": True, "message": "Settings saved"})


@app.route("/api/settings/logo", methods=["POST", "OPTIONS"])
@auth_required()
def upload_logo():
    if request.method == "OPTIONS":
        return "", 204

    if "logo" not in request.files:
        return jsonify({"error": "no_file", "message": "No file uploaded"}), 400

    file = request.files["logo"]
    if not file.filename:
        return jsonify({"error": "no_filename"}), 400

    # Check extension
    filename = secure_filename(file.filename.lower())
    ext = Path(filename).suffix
    if ext not in ALLOWED_IMAGE_EXT:
        return jsonify({
            "error": "invalid_format",
            "message": f"Only PNG, JPG, WEBP allowed (got {ext})"
        }), 400

    # Read file and check size
    file_data = file.read()
    if len(file_data) > MAX_LOGO_SIZE:
        return jsonify({
            "error": "file_too_large",
            "message": "Max 2MB allowed"
        }), 400

    # Validate it's actually an image (using PIL)
    if PIL_AVAILABLE:
        try:
            from io import BytesIO
            img = Image.open(BytesIO(file_data))
            img.verify()
        except Exception as e:
            return jsonify({"error": "invalid_image", "message": "File is not a valid image"}), 400

    # Generate unique filename: logo_{user_id}_{uuid}.{ext}
    user_id = request.current_user["id"]
    new_filename = f"logo_{user_id}_{uuid.uuid4().hex[:8]}{ext}"
    save_path = LOGOS_DIR / new_filename

    # Delete old logo if exists
    old_logo = request.current_user.get("company_logo")
    if old_logo:
        old_path = LOGOS_DIR / Path(old_logo).name
        if old_path.exists():
            try:
                old_path.unlink()
            except Exception:
                pass

    # Save new logo
    try:
        with open(save_path, "wb") as f:
            f.write(file_data)
        # Make readable by nginx
        import os as os_mod
        os_mod.chmod(str(save_path), 0o644)
    except Exception as e:
        log.error(f"logo save error: {e}")
        return jsonify({"error": "save_failed"}), 500

    # Update DB with new logo URL
    logo_url = f"/logos/{new_filename}"
    with get_db() as conn:
        conn.execute(
            "UPDATE users SET company_logo = ? WHERE id = ?",
            (logo_url, user_id),
        )

    log.info(f"logo uploaded for user_id={user_id}: {logo_url}")
    return jsonify({"ok": True, "logo_url": logo_url})


@app.route("/api/settings/logo", methods=["DELETE"])
@auth_required()
def delete_logo():
    user_id = request.current_user["id"]
    old_logo = request.current_user.get("company_logo")

    if old_logo:
        old_path = LOGOS_DIR / Path(old_logo).name
        if old_path.exists():
            try:
                old_path.unlink()
            except Exception:
                pass

    with get_db() as conn:
        conn.execute("UPDATE users SET company_logo = NULL WHERE id = ?", (user_id,))

    return jsonify({"ok": True, "message": "Logo removed"})

'''

# Insert before MAIN marker
main_marker = '# ═══════════════════════════════════════════════════════════════\n# MAIN (dev only - production uses gunicorn)'
if main_marker in content:
    content = content.replace(main_marker, endpoints + '\n' + main_marker)
    with open('/var/www/buildcalcpro/server.py', 'w') as f:
        f.write(content)
    print('OK: Settings endpoints added to server.py')
else:
    print('ERROR: Could not find insertion point')
    import sys
    sys.exit(1)
PYEOF

# 5. Update Nginx to serve /logos/ as static files
echo ""
echo "=== Updating Nginx config ==="

# Check if logos location already in nginx
if ! sudo grep -q "location /logos/" /etc/nginx/sites-available/buildcalcpro; then
    sudo python3 - <<'NGINX_EOF'
with open('/etc/nginx/sites-available/buildcalcpro', 'r') as f:
    cfg = f.read()

# Add /logos/ location BEFORE the /api/ location
logos_loc = '''
    location /logos/ {
        alias /var/www/buildcalcpro/logos/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

'''

if 'location /api/' in cfg:
    cfg = cfg.replace('    location /api/ {', logos_loc + '    location /api/ {', 1)
    with open('/tmp/nginx_buildcalc.conf', 'w') as f:
        f.write(cfg)
    import subprocess
    subprocess.run(['sudo', 'cp', '/tmp/nginx_buildcalc.conf', '/etc/nginx/sites-available/buildcalcpro'])
    print('OK: Nginx /logos/ location added')
else:
    print('WARN: Could not find /api/ in nginx config')
NGINX_EOF
    sudo nginx -t && sudo systemctl reload nginx
    echo "✓ Nginx reloaded with /logos/ location"
else
    echo "✓ Nginx already has /logos/ location"
fi

# 6. Restart Flask service
echo ""
echo "=== Restarting service ==="
sudo systemctl restart buildcalcpro-api
sleep 3
sudo systemctl is-active buildcalcpro-api

# 7. Test endpoints
echo ""
echo "=== Verification ==="
LINES=$(wc -l < /var/www/buildcalcpro/server.py)
echo "✓ server.py now has $LINES lines"
echo ""
HEALTH=$(curl -s https://buildcalcpro.club/api/health)
echo "Health check: $HEALTH"

echo ""
echo "✓ SETTINGS BACKEND INSTALLED"
echo ""
echo "Test endpoints (need to be logged in via browser):"
echo "  GET    /api/settings        - read current settings"
echo "  POST   /api/settings        - update company info"
echo "  POST   /api/settings/logo   - upload logo (multipart/form-data)"
echo "  DELETE /api/settings/logo   - remove logo"
echo ""
echo "Logos are served from: https://buildcalcpro.club/logos/<filename>"
