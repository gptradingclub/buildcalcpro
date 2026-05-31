#!/bin/bash
set -e

echo "=== Installing AI-Powered Pricing Engine ==="
echo ""

# Backup
sudo cp /var/www/buildcalcpro/server.py /var/www/buildcalcpro/server.py.PRE_AI_PRICING
echo "✓ Backup created: server.py.PRE_AI_PRICING"

# Append new endpoint to server.py (just before the main block)
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/server.py', 'r') as f:
    content = f.read()

# Check if endpoint already exists
if "/api/calculate-estimate" in content:
    print("⚠ Endpoint already exists, skipping insertion")
    import sys
    sys.exit(0)

# Find the marker before the __main__ block
marker = '# ═══════════════════════════════════════════════════════════════\n# MAIN (dev only - production uses gunicorn)'

new_endpoint = '''

# ─────────────────────────────────────────────────────────────
# AI MARKET PRICING (PROTECTED - paid users only)
# Returns real market prices for a trade based on specs + region
# ─────────────────────────────────────────────────────────────

@app.route("/api/calculate-estimate", methods=["POST", "OPTIONS"])
@auth_required(require_subscription=True)
def calculate_estimate():
    if request.method == "OPTIONS":
        return "", 204

    ip = get_client_ip()
    if not check_rate_limit(f"estimate:{ip}"):
        return jsonify({"error": "rate_limited"}), 429

    try:
        data = request.get_json(force=True, silent=True) or {}
        trade = data.get("trade", "")
        specs = data.get("specs", {})
        region = data.get("region", "")
        region_label = data.get("region_label", "")
        profit_margin = float(data.get("profit_margin", 15))
        estimate_type = data.get("estimate_type", "Labor + Material")

        if not trade or not specs:
            return jsonify({"error": "trade and specs required"}), 400

        user = request.current_user
        log.info(f"calculate-estimate from user_id={user['id']}: trade={trade} region={region}")

        prompt = f"""You are a construction estimator with access to current US market data via web search.

TASK: Calculate a REALISTIC market-rate estimate for this {trade} project in {region_label or region}.

SPECS:
{json.dumps(specs, indent=2)}

ESTIMATE TYPE: {estimate_type}
REGION: {region_label or region}

Search the web for current 2026 contractor pricing in this region (HomeAdvisor, Angi, Fixr, Forbes Home, local contractor data).

Return ONLY a valid JSON object (no markdown, no explanation) with this exact structure:
{{
  "labor_cost": <integer USD>,
  "material_cost": <integer USD>,
  "labor_hours": <integer>,
  "market_range_low": <integer>,
  "market_range_high": <integer>,
  "confidence": "<high|medium|low>",
  "notes": "<1-2 sentence justification>",
  "sources_checked": [<list of source names>]
}}

CRITICAL:
- Use CURRENT 2026 prices for this specific region
- Be REALISTIC - middle of market, not high-end
- A typical 2000 sqft asphalt shingle roof in Northeast: $15,000-$22,000 total
- A typical 1000 sqft vinyl siding job: $8,000-$13,000 total
- Numbers MUST be integers
- Return ONLY the JSON object"""

        response = anthropic_client.messages.create(
            model="claude-sonnet-4-5",
            max_tokens=1500,
            tools=[{"type": "web_search_20250305", "name": "web_search"}],
            messages=[{"role": "user", "content": prompt}],
        )

        text_parts = []
        for block in response.content:
            if hasattr(block, "text") and block.type == "text":
                text_parts.append(block.text)

        full_text = "\\n".join(text_parts).strip()

        import re as re_mod
        json_match = re_mod.search(r"\\{[\\s\\S]*\\}", full_text)
        if not json_match:
            log.error(f"calculate-estimate: no JSON in response: {full_text[:200]}")
            return jsonify({"error": "ai_response_invalid"}), 500

        try:
            estimate_data = json.loads(json_match.group(0))
        except json.JSONDecodeError as e:
            log.error(f"calculate-estimate: JSON parse error: {e}")
            return jsonify({"error": "ai_response_parse_error"}), 500

        labor = int(estimate_data.get("labor_cost", 0))
        material = int(estimate_data.get("material_cost", 0))
        hours = int(estimate_data.get("labor_hours", 0))

        if estimate_type == "Labor Only":
            base_cost = labor
            material = 0
        elif estimate_type == "Material Only":
            base_cost = material
            labor = 0
            hours = 0
        else:
            base_cost = labor + material

        margin_amount = round(base_cost * (profit_margin / 100))
        total = base_cost + margin_amount

        return jsonify({
            "ok": True,
            "labor": labor,
            "material": material,
            "hours": hours,
            "base_cost": base_cost,
            "margin_amount": margin_amount,
            "margin_percent": profit_margin,
            "total": total,
            "market_range_low": int(estimate_data.get("market_range_low", 0)),
            "market_range_high": int(estimate_data.get("market_range_high", 0)),
            "confidence": estimate_data.get("confidence", "medium"),
            "notes": estimate_data.get("notes", ""),
            "sources": estimate_data.get("sources_checked", []),
            "ai_powered": True,
            "timestamp": datetime.now().isoformat(),
        })

    except Exception as e:
        log.error(f"calculate-estimate ERROR: {e}")
        return jsonify({"error": "internal_error", "message": str(e)}), 500

'''

if marker in content:
    content = content.replace(marker, new_endpoint + '\n' + marker)
    with open('/var/www/buildcalcpro/server.py', 'w') as f:
        f.write(content)
    print("✓ New AI pricing endpoint added to server.py")
else:
    print("✗ Could not find insertion marker")
    import sys
    sys.exit(1)
PYEOF

# Restart service
echo ""
echo "=== Restarting service ==="
sudo systemctl restart buildcalcpro-api
sleep 3
sudo systemctl is-active buildcalcpro-api

# Verify endpoint exists
echo ""
echo "=== Verification ==="
LINES=$(wc -l < /var/www/buildcalcpro/server.py)
echo "✓ server.py now has $LINES lines"
grep -c "calculate-estimate" /var/www/buildcalcpro/server.py || echo "0"

echo ""
echo "✓ AI PRICING ENDPOINT INSTALLED"
echo ""
echo "Test command (from server):"
echo 'curl -s https://buildcalcpro.club/api/health'
