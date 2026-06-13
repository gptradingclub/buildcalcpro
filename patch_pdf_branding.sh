#!/bin/bash
set -e

echo "=== Patching PDF for Custom Branding ==="
echo ""

# Backup
sudo cp /var/www/buildcalcpro/app.html /var/www/buildcalcpro/app.html.PRE_PDF_BRANDING
echo "✓ Backup: app.html.PRE_PDF_BRANDING"

# Patch with Python
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/app.html', 'r', encoding='utf-8') as f:
    content = f.read()

# Check if already patched
if 'window.__BC_COMPANY__' in content:
    print('ALREADY: PDF already patched for custom branding')
    import sys
    sys.exit(0)

# ─── PATCH 1: Replace the PDF header (lines 830-833) ───
old_header = '''  doc.setFillColor(11,13,18);doc.rect(0,0,W,44,"F");
  doc.setFillColor(249,115,22);doc.rect(0,42,W,2.5,"F");
  doc.setTextColor(255,255,255);doc.setFont("helvetica","bold");doc.setFontSize(19);
  doc.text("CONSTRUCTION ESTIMATE PROPOSAL",M,16);
  doc.setFontSize(8);doc.setFont("helvetica","normal");doc.setTextColor(150,150,150);
  doc.text("Construction Estimate",M,24);
  doc.text("gptradingclub@gmail.com",M,31);
  doc.setTextColor(170,170,170);doc.text(today(),W-M,14,{align:"right"});
  doc.text(`Est. #${Date.now().toString().slice(-6)}`,W-M,21,{align:"right"});'''

new_header = '''  doc.setFillColor(11,13,18);doc.rect(0,0,W,44,"F");
  doc.setFillColor(249,115,22);doc.rect(0,42,W,2.5,"F");
  // Custom branding: load user company info from localStorage
  const _bcUser = (function(){try{return JSON.parse(localStorage.getItem("bc_user")||"{}");}catch(e){return {};}})();
  const _cName = _bcUser.company_name || "";
  const _cPhone = _bcUser.company_phone || "";
  const _cEmail = _bcUser.company_email || "";
  const _cAddress = _bcUser.company_address || "";
  const _cWebsite = _bcUser.company_website || "";
  const _cLicense = _bcUser.company_license || "";
  const _cLogo = _bcUser.company_logo || "";
  // If user has custom branding, use it; else use generic header
  if (_cName) {
    doc.setTextColor(255,255,255);doc.setFont("helvetica","bold");doc.setFontSize(19);
    doc.text(_cName.toUpperCase(),M,16);
    doc.setFontSize(8);doc.setFont("helvetica","normal");doc.setTextColor(180,180,190);
    const _line2 = [_cPhone, _cEmail].filter(Boolean).join("  ·  ");
    if (_line2) doc.text(_line2, M, 24);
    const _line3 = [_cAddress, _cWebsite].filter(Boolean).join("  ·  ");
    if (_line3) doc.text(_line3, M, 31);
    if (_cLicense) doc.text("License #: "+_cLicense, M, 38);
  } else {
    doc.setTextColor(255,255,255);doc.setFont("helvetica","bold");doc.setFontSize(19);
    doc.text("CONSTRUCTION ESTIMATE PROPOSAL",M,16);
    doc.setFontSize(8);doc.setFont("helvetica","normal");doc.setTextColor(150,150,150);
    doc.text("Construction Estimate",M,24);
  }
  doc.setTextColor(170,170,170);doc.setFontSize(8);doc.text(today(),W-M,14,{align:"right"});
  doc.text(`Est. #${Date.now().toString().slice(-6)}`,W-M,21,{align:"right"});'''

if old_header in content:
    content = content.replace(old_header, new_header, 1)
    print('OK: PDF header patched')
else:
    print('ERROR: Could not find PDF header pattern')
    import sys
    sys.exit(1)

# ─── PATCH 2: Replace the PDF footer (line 883) ───
old_footer = 'doc.text(`BuildCalc Pro · Gil Pesantez · gptradingclub@gmail.com · © ${new Date().getFullYear()} All Rights Reserved`,M,PH-5);'

new_footer = '''doc.text(((_cName)?(_cName+((_cPhone)?(" · "+_cPhone):"")+((_cEmail)?(" · "+_cEmail):"")):"Construction Estimate Proposal")+` · © ${new Date().getFullYear()}`,M,PH-5);'''

if old_footer in content:
    content = content.replace(old_footer, new_footer, 1)
    print('OK: PDF footer patched')
else:
    print('WARN: Could not find PDF footer pattern - skipping footer')

# ─── PATCH 3: Refresh user info before PDF generation ───
# When doPDF is called, also refresh the user data from /api/auth/me to get latest settings
old_dopdf = '''const doPDF=async()=>{'''
new_dopdf = '''const doPDF=async()=>{
    // Refresh user data from server to get latest company settings
    try {
      const _t = localStorage.getItem("bc_token");
      if (_t) {
        const _r = await fetch("/api/settings", {headers: {"Authorization":"Bearer "+_t}});
        if (_r.ok) {
          const _s = await _r.json();
          if (_s.ok) {
            const _u = JSON.parse(localStorage.getItem("bc_user")||"{}");
            _u.company_name = _s.company_name || "";
            _u.company_phone = _s.company_phone || "";
            _u.company_email = _s.company_email || "";
            _u.company_address = _s.company_address || "";
            _u.company_website = _s.company_website || "";
            _u.company_license = _s.company_license || "";
            _u.company_logo = _s.company_logo || "";
            localStorage.setItem("bc_user", JSON.stringify(_u));
          }
        }
      }
    } catch (e) { console.warn("Could not refresh user settings:", e); }'''

if old_dopdf in content:
    content = content.replace(old_dopdf, new_dopdf, 1)
    print('OK: doPDF now refreshes settings before generating')
else:
    print('WARN: Could not find doPDF function - settings may not refresh')

# Save
with open('/var/www/buildcalcpro/app.html', 'w', encoding='utf-8') as f:
    f.write(content)

print('')
print('✓ PDF patched successfully')
PYEOF

LINES=$(wc -l < /var/www/buildcalcpro/app.html)
echo ""
echo "✓ app.html now has $LINES lines"
echo ""
echo "✓ DONE - Now do a HARD REFRESH (Ctrl+Shift+R) and generate a PDF"
echo ""
echo "IF SOMETHING BREAKS, restore with:"
echo "  sudo cp /var/www/buildcalcpro/app.html.PRE_PDF_BRANDING /var/www/buildcalcpro/app.html"
