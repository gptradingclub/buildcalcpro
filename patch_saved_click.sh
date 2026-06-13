#!/bin/bash
set -e

echo "=== Making Saved Estimates Clickable ==="
echo ""

sudo cp /var/www/buildcalcpro/app.html /var/www/buildcalcpro/app.html.PRE_SAVED_CLICK
echo "✓ Backup: app.html.PRE_SAVED_CLICK"

sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/app.html', 'r', encoding='utf-8') as f:
    content = f.read()

# Check if already patched
if 'loadSavedEstimate' in content:
    print('ALREADY: Saved estimates click already patched')
    import sys
    sys.exit(0)

# ─── PATCH 1: Add the loadSavedEstimate function ───
# We need to add this function inside the component. Find a good anchor near other handlers.

# Anchor: find where doSave is defined (we saw it in the toolbar)
anchor_find = 'const doSave='
if anchor_find not in content:
    print('ERROR: Could not find doSave anchor')
    import sys
    sys.exit(1)

# Find the position of doSave and add loadSavedEstimate before it
load_fn = '''const loadSavedEstimate=(j)=>{
    setTrade(j.tradeKey);
    setSpecs(j.specs||{});
    setMargin(j.margin||15);
    setMode(j.mode||"both");
    setClient(j.client||{});
    setResult(j.result);
    setTab("est");
    setTimeout(()=>resRef.current?.scrollIntoView({behavior:"smooth",block:"start"}),200);
  };
  const deleteSavedEstimate=(id,e)=>{
    e.stopPropagation();
    if(!confirm("Delete this estimate? This cannot be undone."))return;
    setSaved(s=>s.filter(x=>x.id!==id));
  };
  '''

content = content.replace(anchor_find, load_fn + anchor_find, 1)
print('OK: loadSavedEstimate function added')

# ─── PATCH 2: Make the card clickable + add delete button ───
old_card = '''<div key={j.id} className="card fade-up" style={{marginBottom:10,borderColor:TRADES[j.tradeKey]?.color+"22",animationDelay:`${idx*0.05}s`}}>
                  <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",gap:16}}>'''

new_card = '''<div key={j.id} className="card fade-up" onClick={()=>loadSavedEstimate(j)} style={{marginBottom:10,borderColor:TRADES[j.tradeKey]?.color+"22",animationDelay:`${idx*0.05}s`,cursor:"pointer",position:"relative",transition:"transform 0.15s, border-color 0.15s"}} onMouseEnter={(e)=>{e.currentTarget.style.borderColor=TRADES[j.tradeKey]?.color+"66";e.currentTarget.style.transform="translateY(-2px)";}} onMouseLeave={(e)=>{e.currentTarget.style.borderColor=TRADES[j.tradeKey]?.color+"22";e.currentTarget.style.transform="translateY(0)";}}>
                  <button onClick={(e)=>deleteSavedEstimate(j.id,e)} style={{position:"absolute",top:8,right:8,background:"transparent",border:"1px solid #4b5563",color:"#9ca3af",borderRadius:6,padding:"4px 8px",fontSize:11,cursor:"pointer",fontFamily:"inherit",zIndex:10}} title="Delete estimate">🗑️</button>
                  <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",gap:16}}>'''

if old_card in content:
    content = content.replace(old_card, new_card, 1)
    print('OK: Card made clickable with delete button')
else:
    print('ERROR: Could not find card pattern')
    import sys
    sys.exit(1)

# Save
with open('/var/www/buildcalcpro/app.html', 'w', encoding='utf-8') as f:
    f.write(content)

print('')
print('✓ Saved estimates now clickable')
PYEOF

LINES=$(wc -l < /var/www/buildcalcpro/app.html)
echo ""
echo "✓ app.html now has $LINES lines"
echo ""
echo "✓ DONE - Hard refresh (Ctrl+Shift+R) and click on a saved estimate"
echo ""
echo "Features added:"
echo "  - Click on any saved estimate card → loads it for view/PDF/edit"
echo "  - Hover effect (card lifts slightly)"
echo "  - 🗑️ Delete button (top-right of each card)"
echo ""
echo "IF SOMETHING BREAKS:"
echo "  sudo cp /var/www/buildcalcpro/app.html.PRE_SAVED_CLICK /var/www/buildcalcpro/app.html"
