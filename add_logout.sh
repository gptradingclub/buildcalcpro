#!/bin/bash
set -e

echo "=== Adding Logout button to app.html ==="
echo ""

sudo cp /var/www/buildcalcpro/app.html /var/www/buildcalcpro/app.html.PRE_LOGOUT
echo "✓ Backup: app.html.PRE_LOGOUT"

sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/app.html', 'r') as f:
    content = f.read()

# Look for the tabs section in the header (where we have est/saved buttons)
# We'll add the logout button right after them

import re

# Find the pattern of the tab buttons we added in the header
old_tabs = '''{[["est","\u{1f4d0}"],["saved",`\u{1f4c1}${saved.length>0?` ${saved.length}`:""}`]].map(([t,l])=>(
                  <button key={t} className={`tab-btn ${tab===t?"on":""}`} onClick={()=>setTab(t)} style={{padding:"6px 10px",fontSize:12}}>{l}</button>
                ))}'''

# New version with logout button added
new_tabs = '''{[["est","\u{1f4d0}"],["saved",`\u{1f4c1}${saved.length>0?` ${saved.length}`:""}`]].map(([t,l])=>(
                  <button key={t} className={`tab-btn ${tab===t?"on":""}`} onClick={()=>setTab(t)} style={{padding:"6px 10px",fontSize:12}}>{l}</button>
                ))}
                <button onClick={()=>{if(confirm("Sign out?")){localStorage.removeItem("bc_token");localStorage.removeItem("bc_user");window.location.href="/login";}}} style={{padding:"6px 10px",fontSize:12,background:"transparent",border:"1px solid #4b5563",color:"#9ca3af",borderRadius:6,cursor:"pointer",fontFamily:"inherit"}} title="Sign Out">\u{1f6aa}</button>'''

if old_tabs in content:
    content = content.replace(old_tabs, new_tabs)
    with open('/var/www/buildcalcpro/app.html', 'w') as f:
        f.write(content)
    print("✓ Logout button added to header")
else:
    print("⚠ Header pattern not found - trying alternative approach")
    # Alternative: look for the closing of tabs map
    # Just check if we can find the simpler pattern
    if 'setTab(t)}' in content:
        # Find the location of the closing div of the tabs section
        # We need to be more careful here
        marker = 'onClick={()=>setTab(t)} style={{padding:"6px 10px",fontSize:12}}>{l}</button>\n                ))}'
        new_marker = marker + '\n                <button onClick={()=>{if(confirm("Sign out?")){localStorage.removeItem("bc_token");localStorage.removeItem("bc_user");window.location.href="/login";}}} style={{padding:"6px 10px",fontSize:12,background:"transparent",border:"1px solid #4b5563",color:"#9ca3af",borderRadius:6,cursor:"pointer",fontFamily:"inherit"}} title="Sign Out">\u{1f6aa}</button>'
        if marker in content:
            content = content.replace(marker, new_marker)
            with open('/var/www/buildcalcpro/app.html', 'w') as f:
                f.write(content)
            print("✓ Logout button added (alternative approach)")
        else:
            print("✗ Could not find insertion point - manual addition needed")
            import sys
            sys.exit(1)
PYEOF

LINES=$(wc -l < /var/www/buildcalcpro/app.html)
echo ""
echo "✓ app.html now has $LINES lines"
echo ""
echo "✓ DONE - Refresh app in browser (Ctrl+Shift+R) to see Sign Out button"
