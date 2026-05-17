#!/usr/bin/env python3
"""
BuildCalc Pro — Backend API Server
────────────────────────────────────────────────────────────
Proxy seguro entre el frontend (browser) y la API de Anthropic.

ENDPOINTS:
  GET  /api/health           → healthcheck
  POST /api/market-check     → AI Live Market Check (con web search)

REQUISITOS:
  - /etc/buildcalcpro/secrets.env con ANTHROPIC_API_KEY
  - pip install flask anthropic flask-cors gunicorn

USO LOCAL (dev):
  python3 server.py

USO PRODUCCIÓN (con gunicorn):
  gunicorn --bind 127.0.0.1:5050 server:app
"""

import os
import logging
from pathlib import Path
from collections import defaultdict
from datetime import datetime, timedelta

from flask import Flask, request, jsonify
from flask_cors import CORS

try:
    from anthropic import Anthropic
except ImportError:
    print("ERROR: pip install anthropic flask flask-cors gunicorn")
    raise

# ════════════════════════════════════════════════════════════
# CONFIG
# ════════════════════════════════════════════════════════════

SECRETS_FILE = Path("/etc/buildcalcpro/secrets.env")
LOG_FILE = Path("/var/log/buildcalcpro-api.log")

# Rate limit: max 20 requests per IP per hour
RATE_LIMIT_REQUESTS = 20
RATE_LIMIT_WINDOW = timedelta(hours=1)

# Allowed origins (your domain only)
ALLOWED_ORIGINS = [
    "https://buildcalcpro.club",
    "https://www.buildcalcpro.club",
    "http://localhost:8000",  # for local dev testing
]


# ════════════════════════════════════════════════════════════
# LOAD SECRETS
# ════════════════════════════════════════════════════════════

def load_api_key():
    """Lee la API key del archivo seguro /etc/buildcalcpro/secrets.env"""
    if not SECRETS_FILE.exists():
        raise FileNotFoundError(
            f"Secrets file not found: {SECRETS_FILE}\n"
            "Create it with: ANTHROPIC_API_KEY=sk-ant-...."
        )
    for line in SECRETS_FILE.read_text().splitlines():
        line = line.strip()
        if line.startswith("ANTHROPIC_API_KEY="):
            return line.split("=", 1)[1].strip()
    raise ValueError("ANTHROPIC_API_KEY not found in secrets file")


API_KEY = load_api_key()
client = Anthropic(api_key=API_KEY)


# ════════════════════════════════════════════════════════════
# LOGGING
# ════════════════════════════════════════════════════════════

logging.basicConfig(
    filename=str(LOG_FILE),
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("buildcalcpro")


# ════════════════════════════════════════════════════════════
# RATE LIMITING (simple, in-memory)
# ════════════════════════════════════════════════════════════

request_counts = defaultdict(list)


def check_rate_limit(ip):
    """Devuelve True si el IP está dentro del límite"""
    now = datetime.now()
    cutoff = now - RATE_LIMIT_WINDOW
    # Limpiar requests viejos
    request_counts[ip] = [t for t in request_counts[ip] if t > cutoff]
    if len(request_counts[ip]) >= RATE_LIMIT_REQUESTS:
        return False
    request_counts[ip].append(now)
    return True


# ════════════════════════════════════════════════════════════
# FLASK APP
# ════════════════════════════════════════════════════════════

app = Flask(__name__)
CORS(app, origins=ALLOWED_ORIGINS, supports_credentials=False)


@app.route("/api/health", methods=["GET"])
def health():
    """Healthcheck endpoint"""
    return jsonify({
        "status": "ok",
        "service": "buildcalcpro-api",
        "timestamp": datetime.now().isoformat(),
    })


@app.route("/api/market-check", methods=["POST", "OPTIONS"])
def market_check():
    """
    AI Live Market Check — busca precios actuales en web.

    Body esperado:
    {
      "trade": "Roofing",
      "material": "Architectural Shingles",
      "specs": {...},
      "mode": "Labor + Material",
      "region": "Northeast"
    }
    """
    if request.method == "OPTIONS":
        return "", 204

    # Rate limit
    ip = request.headers.get("X-Real-IP") or request.remote_addr or "unknown"
    if not check_rate_limit(ip):
        log.warning(f"Rate limit hit: {ip}")
        return jsonify({
            "error": "Rate limit exceeded",
            "message": "Too many requests. Try again in 1 hour.",
        }), 429

    try:
        data = request.get_json(force=True, silent=True) or {}
        trade = data.get("trade", "")
        material = data.get("material", "")
        specs = data.get("specs", {})
        mode = data.get("mode", "Labor + Material")
        region = data.get("region", "")
        estimate = data.get("estimate", {})

        if not trade:
            return jsonify({"error": "trade is required"}), 400

        log.info(f"market-check from {ip}: trade={trade}, region={region}")

        # Construir el prompt
        prompt = f"""You are a construction estimating expert. Search the web for CURRENT 2026 US market prices.

TRADE: {trade}
REGION: {region}
MATERIAL/TYPE: {material}
MODE: {mode}
SPECS: {specs}

CURRENT ESTIMATE: ${estimate.get('total', 'N/A')} (Labor ${estimate.get('labor', 'N/A')}, Material ${estimate.get('material', 'N/A')})

Search the web for current pricing (HomeAdvisor, Angi, Fixr, Forbes Home, contractor sources).

Provide:
1. Whether the estimate is REASONABLE, LOW, or HIGH for the region
2. Current market range you found (low-high)
3. Key factors affecting price right now (supply chain, season, regional)
4. 1-2 actionable tips for the contractor

Keep response under 200 words. Use simple formatting. No markdown headers, no bullet symbols."""

        # Llamar a Anthropic con web search
        response = client.messages.create(
            model="claude-sonnet-4-5",
            max_tokens=600,
            tools=[{"type": "web_search_20250305", "name": "web_search"}],
            messages=[{"role": "user", "content": prompt}],
        )

        # Extraer texto
        text_parts = []
        for block in response.content:
            if hasattr(block, "text") and block.type == "text":
                text_parts.append(block.text)

        full_text = "\n\n".join(text_parts).strip()

        log.info(f"market-check OK from {ip}: {len(full_text)} chars returned")

        return jsonify({
            "ok": True,
            "analysis": full_text,
            "source": "Live web search via Claude AI",
            "timestamp": datetime.now().isoformat(),
        })

    except Exception as e:
        log.error(f"market-check ERROR from {ip}: {e}")
        return jsonify({
            "error": "Internal error",
            "message": str(e),
        }), 500


# ════════════════════════════════════════════════════════════
# MAIN (dev only)
# ════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print("=" * 50)
    print("BuildCalc Pro API — Development Server")
    print(f"API key loaded: {API_KEY[:20]}...")
    print(f"Allowed origins: {ALLOWED_ORIGINS}")
    print("=" * 50)
    app.run(host="127.0.0.1", port=5050, debug=False)
