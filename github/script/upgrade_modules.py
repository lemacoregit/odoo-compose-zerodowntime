#!/usr/bin/env python3
"""
Odoo CI/CD - Upgrade Module via XML-RPC
Can be run manually to test before integrating into GitHub Actions.

Usage:
    python3 upgrade_modules.py --modules sale,purchase --url http://your-odoo.com
"""

import xmlrpc.client
import argparse
import os
import sys

def upgrade_modules(url: str, db: str, username: str, password: str, modules: list[str]) -> bool:
    print(f"\n{'='*50}")
    print(f"🔧 Odoo Module Upgrader")
    print(f"{'='*50}")
    print(f"URL     : {url}")
    print(f"Database: {db}")
    print(f"Modules : {', '.join(modules)}")
    print(f"{'='*50}\n")

    # Step 1: Authenticate
    print("🔐 Authenticating...")
    common = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/common")
    try:
        version = common.version()
        print(f"✅ Connected to Odoo {version['server_version']}")
    except Exception as e:
        print(f"❌ Cannot connect to Odoo: {e}")
        return False

    uid = common.authenticate(db, username, password, {})
    if not uid:
        print("❌ Authentication failed! Check username/password/database.")
        return False

    print(f"✅ Login successful (uid={uid})\n")

    # Step 2: Find installed modules
    models = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/object")
    installed = models.execute_kw(
        db, uid, password,
        "ir.module.module", "search_read",
        [[["name", "in", modules], ["state", "=", "installed"]]],
        {"fields": ["id", "name", "state", "installed_version"]}
    )

    if not installed:
        print(f"⚠️  No matching installed modules found from: {modules}")
        print("    Make sure the module names are correct and already installed.")
        return True  # not an error, module might be new

    print("📦 Modules to be upgraded:")
    for m in installed:
        print(f"   - {m['name']} (v{m.get('installed_version', '?')})")

    not_found = set(modules) - {m["name"] for m in installed}
    if not_found:
        print(f"\n⚠️  Modules not found or not installed: {', '.join(not_found)}")

    # Step 3: Upgrade
    print("\n🚀 Running upgrade...")
    installed_ids = [m["id"] for m in installed]
    try:
        models.execute_kw(
            db, uid, password,
            "ir.module.module", "button_immediate_upgrade",
            [installed_ids]
        )
        print("🎉 Upgrade completed successfully!")
        return True
    except Exception as e:
        print(f"❌ Upgrade failed: {e}")
        return False


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Upgrade Odoo modules via XML-RPC")
    parser.add_argument("--url",      default=os.getenv("ODOO_URL"),            help="Odoo URL (e.g. https://erp.lemacore.com)")
    parser.add_argument("--db",       default=os.getenv("ODOO_DB"),             help="Database name")
    parser.add_argument("--user",     default=os.getenv("ODOO_ADMIN_USER"),     help="Admin username")
    parser.add_argument("--password", default=os.getenv("ODOO_ADMIN_PASSWORD"), help="Admin password")
    parser.add_argument("--modules",  required=True,                            help="Comma-separated module names")

    args = parser.parse_args()
    modules = [m.strip() for m in args.modules.split(",") if m.strip()]

    if not all([args.url, args.db, args.user, args.password]):
        print("❌ URL, DB, user, and password are required (via args or env vars)")
        sys.exit(1)

    success = upgrade_modules(args.url, args.db, args.user, args.password, modules)
    sys.exit(0 if success else 1)
