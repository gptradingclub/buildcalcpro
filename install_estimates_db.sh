#!/bin/bash
set -e

echo "=== Installing Server-Side Saved Estimates ==="
echo ""

# Backup
sudo cp /var/www/buildcalcpro/server.py /var/www/buildcalcpro/server.py.PRE_ESTIMATES
sudo cp /var/www/buildcalcpro/app.html /var/www/buildcalcpro/app.html.PRE_ESTIMATES
echo "✓ Backups: server.py.PRE_ESTIMATES + app.html.PRE_ESTIMATES"

# 1. Create estimates table in DB
echo ""
echo "=== Creating estimates table ==="
sudo sqlite3 /var/www/buildcalcpro/buildcalc.db <<'SQL_EOF'
CREATE TABLE IF NOT EXISTS estimates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    trade_key TEXT NOT NULL,
    trade_label TEXT NOT NULL,
    specs TEXT NOT NULL,
    region TEXT,
    mode TEXT,
    margin REAL,
    result TEXT NOT NULL,
    client_info TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_estimates_user ON estimates(user_id);
CREATE INDEX IF NOT EXISTS idx_estimates_created ON estimates(created_at DESC);
.schema estimates
SQL_EOF
echo "✓ Estimates table created"

# 2. Add endpoints to server.py
echo ""
echo "=== Adding endpoints to server.py ==="
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/server.py', 'r', encoding='utf-8') as f:
    content = f.read()

if '/api/estimates' in content:
    print('ALREADY: Estimates endpoints exist')
    import sys
    sys.exit(0)

endpoints = '''

# ─────────────────────────────────────────────────────────────
# SAVED ESTIMATES (auth required)
# ─────────────────────────────────────────────────────────────

@app.route("/api/estimates", methods=["GET", "OPTIONS"])
@auth_required()
def list_estimates():
    if request.method == "OPTIONS":
        return "", 204

    user_id = request.current_user["id"]
    with get_db() as conn:
        rows = conn.execute(
            "SELECT id, trade_key, trade_label, specs, region, mode, margin, result, client_info, created_at FROM estimates WHERE user_id = ? ORDER BY created_at DESC LIMIT 100",
            (user_id,)
        ).fetchall()

    estimates = []
    for r in rows:
        try:
            estimates.append({
                "id": r["id"],
                "tradeKey": r["trade_key"],
                "trade": r["trade_label"],
                "specs": json.loads(r["specs"] or "{}"),
                "region": r["region"] or "",
                "mode": r["mode"] or "both",
                "margin": r["margin"] or 15,
                "result": json.loads(r["result"] or "{}"),
                "client": json.loads(r["client_info"] or "{}"),
                "date": r["created_at"],
            })
        except json.JSONDecodeError:
            continue

    return jsonify({"ok": True, "estimates": estimates, "count": len(estimates)})


@app.route("/api/estimates", methods=["POST", "OPTIONS"])
@auth_required()
def create_estimate():
    if request.method == "OPTIONS":
        return "", 204

    data = request.get_json(force=True, silent=True) or {}
    user_id = request.current_user["id"]

    trade_key = (data.get("tradeKey") or "")[:50]
    trade_label = (data.get("trade") or "")[:100]
    specs = data.get("specs") or {}
    region = (data.get("region") or "")[:50]
    mode = (data.get("mode") or "both")[:20]
    margin = float(data.get("margin") or 15)
    result = data.get("result") or {}
    client = data.get("client") or {}

    if not trade_key or not trade_label:
        return jsonify({"error": "missing_required_fields"}), 400

    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO estimates 
               (user_id, trade_key, trade_label, specs, region, mode, margin, result, client_info)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (user_id, trade_key, trade_label,
             json.dumps(specs), region, mode, margin,
             json.dumps(result), json.dumps(client))
        )
        new_id = cur.lastrowid

    log.info(f"estimate saved: user_id={user_id} id={new_id} trade={trade_key}")
    return jsonify({"ok": True, "id": new_id})


@app.route("/api/estimates/<int:estimate_id>", methods=["DELETE", "OPTIONS"])
@auth_required()
def delete_estimate(estimate_id):
    if request.method == "OPTIONS":
        return "", 204

    user_id = request.current_user["id"]
    with get_db() as conn:
        cur = conn.execute(
            "DELETE FROM estimates WHERE id = ? AND user_id = ?",
            (estimate_id, user_id)
        )
        deleted = cur.rowcount

    if deleted == 0:
        return jsonify({"error": "not_found_or_forbidden"}), 404

    log.info(f"estimate deleted: user_id={user_id} id={estimate_id}")
    return jsonify({"ok": True})

'''

# Insert before MAIN marker
marker = '# ═══════════════════════════════════════════════════════════════\n# MAIN (dev only - production uses gunicorn)'
if marker in content:
    content = content.replace(marker, endpoints + '\n' + marker)
    with open('/var/www/buildcalcpro/server.py', 'w', encoding='utf-8') as f:
        f.write(content)
    print('OK: Estimates endpoints added to server.py')
else:
    print('ERROR: Could not find insertion marker')
    import sys
    sys.exit(1)
PYEOF

# 3. Patch app.html to use API instead of localStorage
echo ""
echo "=== Patching app.html to use API ==="
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/app.html', 'r', encoding='utf-8') as f:
    content = f.read()

if 'fetch("/api/estimates"' in content:
    print('ALREADY: app.html already uses API')
    import sys
    sys.exit(0)

# ─── PATCH 1: Replace initial saved state (localStorage load) with empty array ───
# The original code likely has something like: useState(JSON.parse(localStorage.getItem("saved")||"[]"))
import re

# Find the saved state initialization
saved_state_pattern = re.compile(r'const\s*\[\s*saved\s*,\s*setSaved\s*\]\s*=\s*useState\([^)]*\);?')
match = saved_state_pattern.search(content)
if match:
    old_init = match.group(0)
    new_init = 'const [saved,setSaved]=useState([]);'
    content = content.replace(old_init, new_init, 1)
    print(f'OK: saved state init replaced')
else:
    print('WARN: Could not find saved state init pattern')

# ─── PATCH 2: Remove the useEffect that saves to localStorage ───
# Find useEffect that writes "saved" to localStorage
ls_save_pattern = re.compile(r'useEffect\(\(\)\s*=>\s*\{\s*localStorage\.setItem\(\s*["\']saved["\']\s*,\s*JSON\.stringify\(saved\)\s*\)\s*;?\s*\}\s*,\s*\[\s*saved\s*\]\s*\)\s*;?')
match2 = ls_save_pattern.search(content)
if match2:
    old_effect = match2.group(0)
    content = content.replace(old_effect, '// Server-side persistence (no localStorage)', 1)
    print('OK: localStorage save effect removed')

# ─── PATCH 3: Add a function to load estimates from server on mount ───
# Insert after the saved state declaration
load_estimates_code = '''
  // Load saved estimates from server on mount
  useEffect(()=>{
    const token=localStorage.getItem("bc_token");
    if(!token)return;
    fetch("/api/estimates",{headers:{"Authorization":"Bearer "+token}})
      .then(r=>r.ok?r.json():null)
      .then(d=>{if(d&&d.ok&&Array.isArray(d.estimates))setSaved(d.estimates);})
      .catch(e=>console.warn("Could not load estimates:",e));
  },[]);
  '''

# Insert after saved state declaration
if 'const [saved,setSaved]=useState([]);' in content:
    content = content.replace(
        'const [saved,setSaved]=useState([]);',
        'const [saved,setSaved]=useState([]);' + load_estimates_code,
        1
    )
    print('OK: Load estimates from server added')

# ─── PATCH 4: Replace doSave to use API ───
# Find old doSave function
old_dosave_pattern = re.compile(
    r'const\s+doSave\s*=\s*\(\s*\)\s*=>\s*\{[^}]*setSaved\s*\(\s*s\s*=>\s*\[[^\]]+\][^}]*\}\s*;',
    re.DOTALL
)
match3 = old_dosave_pattern.search(content)
if match3:
    old_dosave = match3.group(0)
    new_dosave = '''const doSave=async()=>{
    if(!T||!result)return;
    const token=localStorage.getItem("bc_token");
    if(!token){window.location.href="/login";return;}
    try{
      const r=await fetch("/api/estimates",{
        method:"POST",
        headers:{"Content-Type":"application/json","Authorization":"Bearer "+token},
        body:JSON.stringify({tradeKey:trade,trade:T.label,specs,region,mode,margin,result,client})
      });
      if(r.status===401){localStorage.removeItem("bc_token");window.location.href="/login";return;}
      const d=await r.json();
      if(d.ok){
        // Reload list from server
        const r2=await fetch("/api/estimates",{headers:{"Authorization":"Bearer "+token}});
        if(r2.ok){
          const d2=await r2.json();
          if(d2.ok&&Array.isArray(d2.estimates))setSaved(d2.estimates);
        }
        alert("✓ Estimate saved!");
      }else{
        alert("Could not save estimate. Try again.");
      }
    }catch(e){
      alert("Network error. Could not save.");
    }
  };'''
    content = content.replace(old_dosave, new_dosave, 1)
    print('OK: doSave now uses API')
else:
    print('WARN: Could not find doSave pattern - manual fix may be needed')

# ─── PATCH 5: Update deleteSavedEstimate to use API ───
old_delete = '''const deleteSavedEstimate=(id,e)=>{
    e.stopPropagation();
    if(!confirm("Delete this estimate? This cannot be undone."))return;
    setSaved(s=>s.filter(x=>x.id!==id));
  };'''

new_delete = '''const deleteSavedEstimate=async(id,e)=>{
    e.stopPropagation();
    if(!confirm("Delete this estimate? This cannot be undone."))return;
    const token=localStorage.getItem("bc_token");
    if(!token){window.location.href="/login";return;}
    try{
      const r=await fetch("/api/estimates/"+id,{method:"DELETE",headers:{"Authorization":"Bearer "+token}});
      if(r.ok){setSaved(s=>s.filter(x=>x.id!==id));}
      else{alert("Could not delete.");}
    }catch(err){
      alert("Network error.");
    }
  };'''

if old_delete in content:
    content = content.replace(old_delete, new_delete, 1)
    print('OK: deleteSavedEstimate now uses API')

# Save
with open('/var/www/buildcalcpro/app.html', 'w', encoding='utf-8') as f:
    f.write(content)

print('')
print('✓ Frontend patched')
PYEOF

# 4. Restart service
echo ""
echo "=== Restarting service ==="
sudo systemctl restart buildcalcpro-api
sleep 2
sudo systemctl is-active buildcalcpro-api

echo ""
echo "=== Verification ==="
LINES_SERVER=$(wc -l < /var/www/buildcalcpro/server.py)
LINES_APP=$(wc -l < /var/www/buildcalcpro/app.html)
echo "server.py: $LINES_SERVER lines"
echo "app.html: $LINES_APP lines"

HEALTH=$(curl -s https://buildcalcpro.club/api/health)
echo "Health: $HEALTH"

echo ""
echo "✓ DONE - Server-side estimates ready"
echo ""
echo "Test: Hard refresh, create an estimate, click 'Save Estimate'"
echo "Then close incognito, open new incognito, login → estimates should still be there"
echo ""
echo "IF SOMETHING BREAKS:"
echo "  sudo cp /var/www/buildcalcpro/server.py.PRE_ESTIMATES /var/www/buildcalcpro/server.py"
echo "  sudo cp /var/www/buildcalcpro/app.html.PRE_ESTIMATES /var/www/buildcalcpro/app.html"
echo "  sudo systemctl restart buildcalcpro-api"
