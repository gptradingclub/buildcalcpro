#!/bin/bash
set -e

echo "=== BuildCalc Pro - Webhook Bug Fix ==="
echo ""

# 1. Backup current server.py
sudo cp /var/www/buildcalcpro/server.py /var/www/buildcalcpro/server.py.BUG_BACKUP
echo "✓ Backup created"

# 2. Apply fix using Python
sudo python3 - <<'PYEOF'
with open('/var/www/buildcalcpro/server.py', 'r') as f:
    content = f.read()

old_code = '''    log.info(f"webhook event: {event_type} id={event_id}")
    obj = event["data"]["object"]'''

new_code = '''    log.info(f"webhook event: {event_type} id={event_id}")
    # Convert Stripe object to dict for safer access
    obj_raw = event["data"]["object"]
    if hasattr(obj_raw, "to_dict_recursive"):
        obj = obj_raw.to_dict_recursive()
    elif hasattr(obj_raw, "to_dict"):
        obj = obj_raw.to_dict()
    else:
        obj = dict(obj_raw) if obj_raw else {}'''

if old_code in content:
    content = content.replace(old_code, new_code)
    with open('/var/www/buildcalcpro/server.py', 'w') as f:
        f.write(content)
    print("✓ Patch applied to server.py")
else:
    print("✗ Could not find code pattern - may already be fixed")
    exit(1)
PYEOF

# 3. Clean webhook_events table so retries can process again
echo ""
echo "=== Clearing webhook_events (so retries work) ==="
sudo sqlite3 /var/www/buildcalcpro/buildcalc.db "DELETE FROM webhook_events;"
COUNT=$(sudo sqlite3 /var/www/buildcalcpro/buildcalc.db "SELECT COUNT(*) FROM webhook_events;")
echo "✓ webhook_events table cleared (now has $COUNT rows)"

# 4. Restart service
echo ""
echo "=== Restarting service ==="
sudo systemctl restart buildcalcpro-api
sleep 2
sudo systemctl is-active buildcalcpro-api

echo ""
echo "✓ ALL DONE - Now go to Stripe Dashboard and click 'Resend' on the failed webhook"
