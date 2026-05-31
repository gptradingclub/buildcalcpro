#!/bin/bash
set -e

echo "=== Adding Logout button to app.html ==="
echo ""

# Backup (skip if already exists from previous failed attempt)
if [ ! -f /var/www/buildcalcpro/app.html.PRE_LOGOUT ]; then
    sudo cp /var/www/buildcalcpro/app.html /var/www/buildcalcpro/app.html.PRE_LOGOUT
    echo "✓ Backup created: app.html.PRE_LOGOUT"
else
    echo "✓ Backup already exists"
fi

# Write Python script to file (avoids quote issues in heredoc)
sudo tee /tmp/add_logout.py > /dev/null <<'PYTHON_SCRIPT'
with open('/var/www/buildcalcpro/app.html', 'r', encoding='utf-8') as f:
    content = f.read()

# The anchor: end of the tabs map in the header
anchor = 'onClick={()=>setTab(t)} style={{padding:"6px 10px",fontSize:12}}>{l}</button>\n                ))}'

logout_html = anchor + '\n                <button onClick={()=>{if(confirm("Sign out?")){localStorage.removeItem("bc_token");localStorage.removeItem("bc_user");window.location.href="/login";}}} style={{padding:"6px 10px",fontSize:12,background:"transparent",border:"1px solid #4b5563",color:"#9ca3af",borderRadius:6,cursor:"pointer",fontFamily:"inherit",marginLeft:"4px"}} title="Sign Out">Sign Out</button>'

if anchor in content:
    idx = content.find(anchor)
    check = content[idx:idx+1000]
    if 'Sign out?' in check:
        print('ALREADY: Logout button already present, skipping')
    else:
        content = content.replace(anchor, logout_html, 1)
        with open('/var/www/buildcalcpro/app.html', 'w', encoding='utf-8') as f:
            f.write(content)
        print('OK: Logout button added')
else:
    print('ERROR: Could not find tabs pattern')
    import sys
    sys.exit(1)
PYTHON_SCRIPT

sudo python3 /tmp/add_logout.py

LINES=$(wc -l < /var/www/buildcalcpro/app.html)
echo ""
echo "✓ app.html now has $LINES lines"
echo ""
echo "✓ DONE - Refresh app (Ctrl+Shift+R or new incognito) to see Sign Out button"
