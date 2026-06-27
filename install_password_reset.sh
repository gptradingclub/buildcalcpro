#!/bin/bash
set -e

echo "=== Installing Password Reset System ==="
echo ""

# Backup
sudo cp /var/www/buildcalcpro/server.py /var/www/buildcalcpro/server.py.PRE_PASSWORD
sudo cp /var/www/buildcalcpro/login.html /var/www/buildcalcpro/login.html.PRE_PASSWORD
sudo cp /var/www/buildcalcpro/settings.html /var/www/buildcalcpro/settings.html.PRE_PASSWORD
echo "✓ Backups created"

# 1. Install resend Python SDK
echo ""
echo "=== Installing resend package ==="
sudo pip3 install resend --break-system-packages --quiet
echo "✓ resend installed"

# 2. Create password_resets table
echo ""
echo "=== Creating password_resets table ==="
sudo sqlite3 /var/www/buildcalcpro/buildcalc.db <<'SQL_EOF'
CREATE TABLE IF NOT EXISTS password_resets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    token TEXT UNIQUE NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    used INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_password_resets_token ON password_resets(token);
SQL_EOF
echo "✓ password_resets table created"

# 3. Add endpoints to server.py
echo ""
echo "=== Adding endpoints to server.py ==="
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/server.py', 'r', encoding='utf-8') as f:
    content = f.read()

if '/api/auth/forgot-password' in content:
    print('ALREADY: Password endpoints exist')
    import sys
    sys.exit(0)

# Add imports
import_addition = '''
import secrets as secrets_mod
try:
    import resend
    RESEND_AVAILABLE = True
except ImportError:
    RESEND_AVAILABLE = False

RESEND_API_KEY = os.environ.get("RESEND_API_KEY", "")
if RESEND_AVAILABLE and RESEND_API_KEY:
    resend.api_key = RESEND_API_KEY

'''
marker = 'try:\n    from anthropic import Anthropic'
if marker in content:
    content = content.replace(marker, import_addition + marker, 1)

# Add endpoints
endpoints = '''

# ─────────────────────────────────────────────────────────────
# PASSWORD MANAGEMENT
# ─────────────────────────────────────────────────────────────

@app.route("/api/auth/forgot-password", methods=["POST", "OPTIONS"])
def forgot_password():
    if request.method == "OPTIONS":
        return "", 204

    data = request.get_json(force=True, silent=True) or {}
    email = (data.get("email") or "").strip().lower()

    if not email:
        return jsonify({"error": "email_required"}), 400

    # Always return success (don't leak whether email exists)
    response_msg = {"ok": True, "message": "If that email exists, a reset link has been sent."}

    with get_db() as conn:
        user = conn.execute("SELECT id, email FROM users WHERE email = ?", (email,)).fetchone()

    if not user:
        log.info(f"forgot-password: unknown email {email}")
        return jsonify(response_msg)

    # Generate secure token (1 hour expiry)
    token = secrets_mod.token_urlsafe(32)
    expires_at = datetime.utcnow() + timedelta(hours=1)

    with get_db() as conn:
        conn.execute(
            "INSERT INTO password_resets (user_id, token, expires_at) VALUES (?, ?, ?)",
            (user["id"], token, expires_at.isoformat())
        )

    reset_url = f"https://buildcalcpro.club/reset-password?token={token}"

    # Send email via Resend
    if RESEND_AVAILABLE and RESEND_API_KEY:
        try:
            resend.Emails.send({
                "from": "BuildCalc Pro <onboarding@resend.dev>",
                "to": user["email"],
                "subject": "Reset your BuildCalc Pro password",
                "html": f"""<div style="font-family: Arial, sans-serif; max-width: 560px; margin: 0 auto; padding: 20px;">
                    <h1 style="color: #f97316;">Reset Your Password</h1>
                    <p>Hi,</p>
                    <p>We received a request to reset your BuildCalc Pro password.</p>
                    <p>Click the button below to set a new password. This link expires in 1 hour.</p>
                    <p style="margin: 30px 0;">
                        <a href="{reset_url}" style="background: #f97316; color: white; padding: 14px 28px; text-decoration: none; border-radius: 8px; font-weight: bold;">Reset Password</a>
                    </p>
                    <p>Or copy this link: <br><a href="{reset_url}">{reset_url}</a></p>
                    <p style="color: #666; font-size: 13px; margin-top: 30px;">If you didn't request this, you can safely ignore this email. Your password will not change.</p>
                    <hr style="margin: 30px 0; border: none; border-top: 1px solid #eee;">
                    <p style="color: #999; font-size: 12px;">BuildCalc Pro · AI-Powered Construction Estimator</p>
                </div>"""
            })
            log.info(f"reset email sent to {email}")
        except Exception as e:
            log.error(f"resend email failed: {e}")

    return jsonify(response_msg)


@app.route("/api/auth/reset-password", methods=["POST", "OPTIONS"])
def reset_password():
    if request.method == "OPTIONS":
        return "", 204

    data = request.get_json(force=True, silent=True) or {}
    token = (data.get("token") or "").strip()
    new_password = data.get("password") or ""

    if not token or not new_password:
        return jsonify({"error": "token_and_password_required"}), 400

    if len(new_password) < 8:
        return jsonify({"error": "password_too_short", "message": "Password must be at least 8 characters."}), 400

    with get_db() as conn:
        reset = conn.execute(
            "SELECT id, user_id, expires_at, used FROM password_resets WHERE token = ?",
            (token,)
        ).fetchone()

    if not reset:
        return jsonify({"error": "invalid_token"}), 400

    if reset["used"]:
        return jsonify({"error": "token_already_used"}), 400

    expires_at = datetime.fromisoformat(reset["expires_at"])
    if datetime.utcnow() > expires_at:
        return jsonify({"error": "token_expired"}), 400

    # Hash new password and update user
    new_hash = bcrypt.hashpw(new_password.encode(), bcrypt.gensalt()).decode()

    with get_db() as conn:
        conn.execute("UPDATE users SET password_hash = ? WHERE id = ?", (new_hash, reset["user_id"]))
        conn.execute("UPDATE password_resets SET used = 1 WHERE id = ?", (reset["id"],))

    log.info(f"password reset completed for user_id={reset['user_id']}")
    return jsonify({"ok": True, "message": "Password updated. You can now log in."})


@app.route("/api/auth/change-password", methods=["POST", "OPTIONS"])
@auth_required()
def change_password():
    if request.method == "OPTIONS":
        return "", 204

    data = request.get_json(force=True, silent=True) or {}
    current_password = data.get("current_password") or ""
    new_password = data.get("new_password") or ""
    user_id = request.current_user["id"]

    if not current_password or not new_password:
        return jsonify({"error": "both_passwords_required"}), 400

    if len(new_password) < 8:
        return jsonify({"error": "password_too_short", "message": "New password must be at least 8 characters."}), 400

    # Verify current password
    with get_db() as conn:
        user = conn.execute("SELECT password_hash FROM users WHERE id = ?", (user_id,)).fetchone()

    if not user or not bcrypt.checkpw(current_password.encode(), user["password_hash"].encode()):
        return jsonify({"error": "incorrect_current_password"}), 400

    # Hash and update
    new_hash = bcrypt.hashpw(new_password.encode(), bcrypt.gensalt()).decode()
    with get_db() as conn:
        conn.execute("UPDATE users SET password_hash = ? WHERE id = ?", (new_hash, user_id))

    log.info(f"password changed for user_id={user_id}")
    return jsonify({"ok": True, "message": "Password updated."})

'''

main_marker = '# ═══════════════════════════════════════════════════════════════\n# MAIN (dev only - production uses gunicorn)'
if main_marker in content:
    content = content.replace(main_marker, endpoints + '\n' + main_marker)
    with open('/var/www/buildcalcpro/server.py', 'w', encoding='utf-8') as f:
        f.write(content)
    print('OK: Endpoints added')
else:
    print('ERROR: Could not find insertion marker')
    import sys
    sys.exit(1)
PYEOF

# 4. Create reset-password.html
echo ""
echo "=== Creating reset-password.html ==="
sudo tee /var/www/buildcalcpro/reset-password.html > /dev/null <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Reset Password — BuildCalc Pro</title>
<link href="https://fonts.googleapis.com/css2?family=Syne:wght@700;800;900&family=Space+Grotesk:wght@500;600;700&family=DM+Mono:wght@300;400;500&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{background:#0a0c12;color:#fff;font-family:'DM Mono',monospace;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.card{background:linear-gradient(180deg,#11141c,#0a0c12);border:1px solid #1f2937;border-radius:18px;padding:40px;max-width:440px;width:100%}
.logo{display:flex;align-items:center;gap:10px;justify-content:center;margin-bottom:30px}
.logo-mark{width:40px;height:40px;background:linear-gradient(135deg,#f97316,#ea580c);border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:900}
.logo-text{font-family:'Syne',sans-serif;font-weight:900;font-size:18px;letter-spacing:1px}
.logo-pro{background:#f97316;font-size:9px;padding:3px 7px;border-radius:4px;font-weight:700;letter-spacing:1.5px;margin-left:4px}
h1{font-family:'Syne',sans-serif;font-size:22px;font-weight:900;margin-bottom:10px;text-align:center}
.sub{color:#9ca3af;font-size:13px;text-align:center;margin-bottom:24px}
.form-group{margin-bottom:18px}
.form-label{display:block;font-size:11px;font-weight:600;letter-spacing:1.5px;text-transform:uppercase;margin-bottom:8px}
.form-input{width:100%;background:#0a0c12;border:1px solid #4b5563;color:#fff;padding:12px 14px;border-radius:8px;font-family:'DM Mono',monospace;font-size:13px;outline:none}
.form-input:focus{border-color:#f97316}
.btn{width:100%;background:linear-gradient(135deg,#f97316,#ea580c);color:#fff;border:none;padding:14px;border-radius:8px;font-family:'Syne',sans-serif;font-weight:800;font-size:13px;letter-spacing:1.5px;text-transform:uppercase;cursor:pointer;box-shadow:0 8px 20px rgba(249,115,22,.3)}
.btn:disabled{opacity:.5;cursor:wait}
.message{padding:12px 16px;border-radius:8px;font-size:13px;margin-bottom:18px;display:none;text-align:center}
.message.error{background:rgba(239,68,68,.1);border:1px solid rgba(239,68,68,.3);color:#fca5a5;display:block}
.message.success{background:rgba(34,197,94,.1);border:1px solid rgba(34,197,94,.3);color:#86efac;display:block}
a{color:#f97316;text-decoration:none}
.center-link{text-align:center;margin-top:20px;font-size:12px}
</style>
</head>
<body>
<div class="card">
  <div class="logo">
    <div class="logo-mark">🏗️</div>
    <div class="logo-text">BUILDCALC<span class="logo-pro">PRO</span></div>
  </div>
  <h1>Reset Password</h1>
  <p class="sub">Choose a new password (min 8 characters)</p>
  <div id="message" class="message"></div>
  <form id="reset-form">
    <div class="form-group">
      <label class="form-label">New Password</label>
      <input type="password" id="password" class="form-input" minlength="8" required>
    </div>
    <div class="form-group">
      <label class="form-label">Confirm Password</label>
      <input type="password" id="password2" class="form-input" minlength="8" required>
    </div>
    <button type="submit" class="btn" id="submit-btn">Update Password</button>
  </form>
  <p class="center-link"><a href="/login">← Back to Login</a></p>
</div>
<script>
const params = new URLSearchParams(window.location.search);
const token = params.get('token');
const msg = document.getElementById('message');
const btn = document.getElementById('submit-btn');

if (!token) {
  msg.className = 'message error';
  msg.textContent = 'Invalid reset link.';
  document.getElementById('reset-form').style.display = 'none';
}

document.getElementById('reset-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const p1 = document.getElementById('password').value;
  const p2 = document.getElementById('password2').value;

  if (p1 !== p2) {
    msg.className = 'message error';
    msg.textContent = 'Passwords do not match.';
    return;
  }
  if (p1.length < 8) {
    msg.className = 'message error';
    msg.textContent = 'Password must be at least 8 characters.';
    return;
  }

  btn.disabled = true;
  btn.textContent = 'Updating...';
  try {
    const r = await fetch('/api/auth/reset-password', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({token: token, password: p1})
    });
    const data = await r.json();
    if (data.ok) {
      msg.className = 'message success';
      msg.textContent = '✓ Password updated! Redirecting to login...';
      setTimeout(() => window.location.href = '/login', 2000);
    } else {
      msg.className = 'message error';
      msg.textContent = data.message || 'Could not reset password. Link may have expired.';
      btn.disabled = false;
      btn.textContent = 'Update Password';
    }
  } catch (err) {
    msg.className = 'message error';
    msg.textContent = 'Network error. Try again.';
    btn.disabled = false;
    btn.textContent = 'Update Password';
  }
});
</script>
</body>
</html>
HTML_EOF
echo "✓ reset-password.html created"

# 5. Add nginx route
echo ""
echo "=== Adding /reset-password to Nginx ==="
if ! sudo grep -q "location = /reset-password" /etc/nginx/sites-available/buildcalcpro; then
    sudo python3 - <<'NGINX_EOF'
with open('/etc/nginx/sites-available/buildcalcpro', 'r') as f:
    cfg = f.read()

new_routes = """    location = /reset-password { try_files /reset-password.html =404; }
    location = /reset-password/ { try_files /reset-password.html =404; }
    location = /settings { try_files /settings.html =404; }"""

old_route = "    location = /settings { try_files /settings.html =404; }"

if old_route in cfg and "location = /reset-password" not in cfg:
    cfg = cfg.replace(old_route, new_routes, 1)
    with open('/tmp/nginx_bcp.conf', 'w') as f:
        f.write(cfg)
    import subprocess
    subprocess.run(['sudo', 'cp', '/tmp/nginx_bcp.conf', '/etc/nginx/sites-available/buildcalcpro'])
    print('OK: /reset-password route added')
NGINX_EOF
    sudo nginx -t && sudo systemctl reload nginx
    echo "✓ Nginx reloaded"
fi

# 6. Add "Forgot password?" link to login.html
echo ""
echo "=== Adding 'Forgot password?' link to login.html ==="
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/login.html', 'r', encoding='utf-8') as f:
    content = f.read()

if 'Forgot password' in content:
    print('ALREADY: Forgot password link exists')
    import sys
    sys.exit(0)

# Find the submit button or end of form to add the link before
# Look for a common pattern
import re

# Try to add before the </form> closing tag
if '</form>' in content:
    forgot_link = '<p style="text-align:center;margin-top:14px;font-size:12px;"><a href="#" id="forgot-link" style="color:#f97316;text-decoration:none;">Forgot password?</a></p>'
    content = content.replace('</form>', forgot_link + '\n</form>', 1)

# Add the forgot password handler script before </body>
forgot_script = '''
<script>
document.getElementById('forgot-link')?.addEventListener('click', async (e) => {
  e.preventDefault();
  const email = prompt('Enter your email to receive a password reset link:');
  if (!email) return;
  try {
    const r = await fetch('/api/auth/forgot-password', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({email: email.trim().toLowerCase()})
    });
    const data = await r.json();
    alert(data.message || 'If that email exists, a reset link has been sent. Check your inbox.');
  } catch (err) {
    alert('Network error. Try again.');
  }
});
</script>
'''

if '</body>' in content:
    content = content.replace('</body>', forgot_script + '\n</body>', 1)

with open('/var/www/buildcalcpro/login.html', 'w', encoding='utf-8') as f:
    f.write(content)
print('OK: Forgot password link added to login')
PYEOF

# 7. Restart service
echo ""
echo "=== Restarting service ==="
sudo systemctl restart buildcalcpro-api
sleep 3
sudo systemctl is-active buildcalcpro-api

echo ""
echo "=== Verification ==="
HEALTH=$(curl -s https://buildcalcpro.club/api/health)
echo "Health: $HEALTH"

echo ""
echo "✓ PASSWORD RESET INSTALLED"
echo ""
echo "Test:"
echo "  1. Visit https://buildcalcpro.club/login"
echo "  2. Click 'Forgot password?'"
echo "  3. Enter your email"
echo "  4. Check inbox for reset email (from onboarding@resend.dev)"
echo "  5. Click reset link → set new password"
echo ""
echo "IF SOMETHING BREAKS:"
echo "  sudo cp /var/www/buildcalcpro/server.py.PRE_PASSWORD /var/www/buildcalcpro/server.py"
echo "  sudo cp /var/www/buildcalcpro/login.html.PRE_PASSWORD /var/www/buildcalcpro/login.html"
echo "  sudo systemctl restart buildcalcpro-api"
