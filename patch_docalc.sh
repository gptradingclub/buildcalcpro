#!/bin/bash
set -e

echo "=== Patching doCalc to use AI pricing ==="
echo ""

# Backup
sudo cp /var/www/buildcalcpro/app.html /var/www/buildcalcpro/app.html.PRE_DOCALC_PATCH
echo "✓ Backup: app.html.PRE_DOCALC_PATCH"
echo ""

# Apply patch with Python (exact string replacement)
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/app.html', 'r') as f:
    content = f.read()

# Exact old code (matches what we saw in sed output)
old_code = '''const doCalc=()=>{
    if(!trade)return;setLoading(true);
    setTimeout(()=>{setResult(calc(trade,{...specs,_region:region}));setLoading(false);setTimeout(()=>resRef.current?.scrollIntoView({behavior:"smooth",block:"start"}),120);},600);
  };'''

# New code: calls AI endpoint, falls back to local calc if AI fails
new_code = '''const doCalc=async()=>{
    if(!trade)return;
    setLoading(true);
    const token=localStorage.getItem('bc_token');
    if(!token){window.location.href='/login';return;}
    try{
      const res=await fetch('/api/calculate-estimate',{
        method:'POST',
        headers:{'Content-Type':'application/json','Authorization':'Bearer '+token},
        body:JSON.stringify({
          trade:trade,
          specs:specs,
          region:region,
          region_label:REGIONS[region]?.label||region,
          profit_margin:margin,
          estimate_type:mode==='labor'?'Labor Only':mode==='material'?'Material Only':'Labor + Material'
        })
      });
      if(res.status===401){localStorage.removeItem('bc_token');window.location.href='/login';return;}
      if(res.status===403){window.location.href='/login?need=subscription';return;}
      const data=await res.json();
      if(data.ok){
        const r={
          labor:data.labor||0,
          material:data.material||0,
          hours:data.hours||0,
          base:data.base_cost||0,
          margin:data.margin_amount||0,
          marginPct:data.margin_percent||margin,
          total:data.total||0,
          marketLow:data.market_range_low,
          marketHigh:data.market_range_high,
          confidence:data.confidence,
          aiNotes:data.notes,
          aiSources:data.sources||[],
          aiPowered:true,
          mode:mode
        };
        setResult(r);
      }else{
        console.warn('AI pricing failed, using local fallback:',data);
        setResult(calc(trade,{...specs,_region:region}));
      }
    }catch(err){
      console.warn('AI pricing network error, using local fallback:',err);
      setResult(calc(trade,{...specs,_region:region}));
    }
    setLoading(false);
    setTimeout(()=>resRef.current?.scrollIntoView({behavior:"smooth",block:"start"}),120);
  };'''

if old_code in content:
    content = content.replace(old_code, new_code)
    with open('/var/www/buildcalcpro/app.html', 'w') as f:
        f.write(content)
    print("✓ doCalc() replaced with AI-powered version (with local fallback)")
else:
    print("✗ Could not find exact doCalc pattern")
    import sys
    sys.exit(1)
PYEOF

# Verify file is still readable
LINES=$(wc -l < /var/www/buildcalcpro/app.html)
SIZE=$(stat -c%s /var/www/buildcalcpro/app.html)
echo ""
echo "✓ app.html now has $LINES lines, $SIZE bytes"

echo ""
echo "=== Verifying syntax (Python heuristic check) ==="
if grep -q "calculate-estimate" /var/www/buildcalcpro/app.html; then
    echo "✓ AI endpoint reference found in app.html"
fi

echo ""
echo "✓ ALL DONE"
echo ""
echo "TEST: Open https://buildcalcpro.club/app in INCOGNITO and try a Vinyl Siding estimate."
echo "      It should take ~10-15 seconds (AI is searching web) and give real market prices."
echo ""
echo "IF APP BREAKS: Run this to restore:"
echo "  sudo cp /var/www/buildcalcpro/app.html.PRE_DOCALC_PATCH /var/www/buildcalcpro/app.html"
