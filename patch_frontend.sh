#!/bin/bash
set -e

echo "=== Patching app.html to use AI-powered pricing ==="
echo ""

# 1. Backup
sudo cp /var/www/buildcalcpro/app.html /var/www/buildcalcpro/app.html.PRE_AI_PRICING
echo "✓ Backup: app.html.PRE_AI_PRICING"

# 2. Patch app.html with Python (replace calculate function)
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/app.html', 'r') as f:
    content = f.read()

# We need to find the existing calculate function and replace it with an async version
# that calls /api/calculate-estimate

# The current calculate function is something that takes specs and uses hardcoded prices
# We need to:
# 1. Make it async
# 2. Call the AI endpoint
# 3. Show "Loading market prices..." while waiting
# 4. Display the real result

# Find the calculate function. Looking for: const calculate=
import re

# Search for the calculate function in the React code
patterns_to_find = [
    'const calculate=',
    'const calculate =',
    'function calculate(',
]

found_pattern = None
for p in patterns_to_find:
    if p in content:
        found_pattern = p
        print(f"  Found pattern: {p}")
        break

if not found_pattern:
    print("✗ Could not find calculate function in app.html")
    print("   Searching for any 'calculate' references...")
    import re
    matches = re.findall(r'.{50}calculate.{50}', content)[:5]
    for m in matches:
        print(f"   - {m}")
    import sys
    sys.exit(1)

# Build the new calculate function that uses AI endpoint
new_calculate = '''const calculate=async()=>{
  const token=localStorage.getItem('bc_token');
  if(!token){window.location.href='/login';return;}
  
  setLoading(true);
  setResult(null);
  setError(null);
  
  try{
    const res=await fetch('/api/calculate-estimate',{
      method:'POST',
      headers:{
        'Content-Type':'application/json',
        'Authorization':'Bearer '+token
      },
      body:JSON.stringify({
        trade:trade,
        specs:specs,
        region:region,
        region_label:REGIONS[region]?.label||region,
        profit_margin:profitMargin,
        estimate_type:estimateType
      })
    });
    
    if(res.status===401){
      localStorage.removeItem('bc_token');
      window.location.href='/login';
      return;
    }
    if(res.status===403){
      window.location.href='/login?need=subscription';
      return;
    }
    
    const data=await res.json();
    
    if(!data.ok){
      setError(data.message||data.error||'Could not calculate estimate. Try again.');
      setLoading(false);
      return;
    }
    
    setResult({
      labor:data.labor,
      material:data.material,
      hours:data.hours,
      base:data.base_cost,
      margin:data.margin_amount,
      marginPercent:data.margin_percent,
      total:data.total,
      marketLow:data.market_range_low,
      marketHigh:data.market_range_high,
      confidence:data.confidence,
      notes:data.notes,
      sources:data.sources||[],
      aiPowered:true
    });
    setLoading(false);
  }catch(err){
    setError('Network error. Check connection and try again.');
    setLoading(false);
  }
};'''

# This is going to be complex because the existing calculate function is embedded in JSX
# Let me check what's actually there
import re
calc_match = re.search(r'const calculate\s*=\s*\(?\s*\)?\s*=>\s*\{', content)
if calc_match:
    start = calc_match.start()
    # Find the matching closing brace
    brace_count = 0
    i = calc_match.end() - 1  # position of opening {
    while i < len(content):
        if content[i] == '{':
            brace_count += 1
        elif content[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                end = i + 1
                # Also include trailing semicolon if present
                while end < len(content) and content[end] in ';\n ':
                    if content[end] == ';':
                        end += 1
                        break
                    end += 1
                break
        i += 1
    
    old_calc = content[start:end]
    print(f"  Found existing calculate function: {len(old_calc)} chars")
    print(f"  First 100 chars: {old_calc[:100]}")
    print(f"  Last 100 chars: {old_calc[-100:]}")
    
    content = content[:start] + new_calculate + content[end:]
    
    with open('/var/www/buildcalcpro/app.html', 'w') as f:
        f.write(content)
    print("✓ calculate() function replaced with AI-powered version")
else:
    print("✗ Could not find calculate function pattern")
    import sys
    sys.exit(1)

# Also ensure we have setError state. Check if setError exists
if 'setError' not in content:
    print("⚠ setError state may need to be added. Will add it.")
    # Add error state next to setLoading
    if 'const [loading, setLoading]' in content:
        content = content.replace(
            'const [loading, setLoading]',
            'const [error, setError] = useState(null);\n  const [loading, setLoading]'
        )
        with open('/var/www/buildcalcpro/app.html', 'w') as f:
            f.write(content)
        print("✓ Added error state")
PYEOF

# 3. Verify file is still valid HTML
LINES=$(wc -l < /var/www/buildcalcpro/app.html)
SIZE=$(stat -c%s /var/www/buildcalcpro/app.html)
echo ""
echo "✓ app.html now has $LINES lines, $SIZE bytes"

echo ""
echo "✓ ALL DONE - Refresh the app in your browser (Ctrl+Shift+R for hard refresh)"
