#!/usr/bin/env python3
"""
BuildCalc Pro — Database Setup Script
─────────────────────────────────────────
Crea la base de datos SQLite con la tabla users.

USO:
  sudo python3 auth_setup.py

Solo se corre 1 vez para inicializar la DB.
"""

import sqlite3
from pathlib import Path
import sys

DB_PATH = Path("/var/www/buildcalcpro/buildcalc.db")

def init_database():
    """Crea la base de datos y la tabla users"""
    print(f"📦 Creating database at: {DB_PATH}")

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    # Tabla USERS
    cur.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            stripe_customer_id TEXT,
            stripe_subscription_id TEXT,
            subscription_status TEXT DEFAULT 'inactive',
            subscription_end_date TIMESTAMP,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            last_login TIMESTAMP,
            login_count INTEGER DEFAULT 0
        )
    """)

    # Tabla SESSIONS (para JWT tokens revocados, opcional)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS revoked_tokens (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token_jti TEXT UNIQUE NOT NULL,
            revoked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)

    # Tabla WEBHOOK_EVENTS (para idempotency con Stripe)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS webhook_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            stripe_event_id TEXT UNIQUE NOT NULL,
            event_type TEXT NOT NULL,
            processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)

    # Índices para queries rápidas
    cur.execute("CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_users_stripe_customer ON users(stripe_customer_id)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_users_status ON users(subscription_status)")

    conn.commit()

    # Verificar tablas creadas
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = [row[0] for row in cur.fetchall()]

    print(f"\n✅ Database created successfully")
    print(f"📋 Tables created:")
    for t in tables:
        cur.execute(f"SELECT COUNT(*) FROM {t}")
        count = cur.fetchone()[0]
        print(f"   • {t} ({count} rows)")

    conn.close()
    print(f"\n🔒 Setting permissions...")

if __name__ == "__main__":
    if DB_PATH.exists():
        print(f"⚠️  Database already exists at {DB_PATH}")
        response = input("Recreate? (yes/no): ")
        if response.lower() != "yes":
            print("Aborted.")
            sys.exit(0)
        DB_PATH.unlink()
        print("Old database removed.")

    init_database()

    print(f"\n✅ DONE! Now run:")
    print(f"   sudo chown www-data:www-data {DB_PATH}")
    print(f"   sudo chmod 660 {DB_PATH}")
