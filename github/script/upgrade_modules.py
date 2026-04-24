#!/usr/bin/env python3
"""
Odoo CI/CD - Upgrade modules via XML-RPC.
Can be run manually or called from GitHub Actions.

Usage:
    python3 upgrade_modules.py --modules sale,purchase --url https://zerodowntime.lemacore.com
"""

import xmlrpc.client
import argparse
import os
import sys
import time
import http.client
import urllib.parse


class _TimeoutTransport(xmlrpc.client.SafeTransport):
    """XML-RPC transport with configurable socket timeout."""

    def __init__(self, timeout: int = 60, **kwargs):
        super().__init__(**kwargs)
        self._timeout = timeout

    def make_connection(self, host):
        conn = super().make_connection(host)
        conn.timeout = self._timeout
        return conn


def _make_proxy(url: str, path: str, timeout: int) -> xmlrpc.client.ServerProxy:
    parsed = urllib.parse.urlparse(url)
    # _TimeoutTransport extends SafeTransport (HTTPS only).
    # For plain HTTP the default transport is used; production should always use HTTPS.
    transport = _TimeoutTransport(timeout=timeout) if parsed.scheme == "https" else None
    return xmlrpc.client.ServerProxy(f"{url}{path}", transport=transport, allow_none=True)


def _retry(fn, attempts: int = 3, delay: float = 5.0, label: str = ""):
    """Call fn up to `attempts` times with exponential backoff."""
    for attempt in range(1, attempts + 1):
        try:
            return fn()
        except Exception as exc:
            if attempt == attempts:
                raise
            wait = delay * (2 ** (attempt - 1))
            print(f"  Attempt {attempt}/{attempts} failed for {label}: {exc} -- retrying in {wait:.0f}s")
            time.sleep(wait)


def upgrade_modules(
    url: str,
    db: str,
    username: str,
    password: str,
    modules: list,
    timeout: int = 60,
) -> bool:
    print(f"\n{'=' * 52}")
    print("  Odoo Module Upgrader")
    print(f"{'=' * 52}")
    print(f"  URL     : {url}")
    print(f"  Database: {db}")
    print(f"  Modules : {', '.join(modules)}")
    print(f"  Timeout : {timeout}s per call")
    print(f"{'=' * 52}\n")

    # Step 1: Connect and authenticate
    print("Authenticating...")
    common = _make_proxy(url, "/xmlrpc/2/common", timeout)

    try:
        version = _retry(lambda: common.version(), label="version check")
        print(f"  Connected to Odoo {version['server_version']}")
    except Exception as exc:
        print(f"  ERROR: Cannot connect to Odoo: {exc}")
        return False

    try:
        uid = _retry(lambda: common.authenticate(db, username, password, {}), label="authenticate")
    except Exception as exc:
        print(f"  ERROR: Authentication request failed: {exc}")
        return False

    if not uid:
        print("  ERROR: Authentication failed — check username, password, and database name.")
        return False

    print(f"  Authenticated (uid={uid})\n")

    # Step 2: Find installed modules
    models = _make_proxy(url, "/xmlrpc/2/object", timeout)

    try:
        installed = _retry(
            lambda: models.execute_kw(
                db, uid, password,
                "ir.module.module", "search_read",
                [[["name", "in", modules], ["state", "=", "installed"]]],
                {"fields": ["id", "name", "state", "installed_version"]},
            ),
            label="search modules",
        )
    except Exception as exc:
        print(f"  ERROR: Failed to query modules: {exc}")
        return False

    if not installed:
        print(f"  WARNING: No matching installed modules found from: {modules}")
        print("  Make sure the module names are correct and already installed in Odoo.")
        return True

    print("Modules to upgrade:")
    for m in installed:
        print(f"  - {m['name']} (current: v{m.get('installed_version', '?')})")

    not_found = set(modules) - {m["name"] for m in installed}
    if not_found:
        print(f"\n  WARNING: Not found or not installed: {', '.join(sorted(not_found))}")

    # Step 3: Trigger upgrade
    installed_ids = [m["id"] for m in installed]
    print("\nRunning upgrade...")
    try:
        _retry(
            lambda: models.execute_kw(
                db, uid, password,
                "ir.module.module", "button_immediate_upgrade",
                [installed_ids],
            ),
            label="upgrade",
        )
    except Exception as exc:
        print(f"  ERROR: Upgrade failed: {exc}")
        return False

    # Step 4: Verify post-upgrade state
    print("\nVerifying upgrade result...")
    try:
        post = _retry(
            lambda: models.execute_kw(
                db, uid, password,
                "ir.module.module", "search_read",
                [[["id", "in", installed_ids]]],
                {"fields": ["name", "state", "installed_version"]},
            ),
            label="post-upgrade verify",
        )
        all_ok = True
        for m in post:
            if m["state"] == "installed":
                print(f"  OK  {m['name']} -> v{m.get('installed_version', '?')}")
            else:
                print(f"  FAIL {m['name']} -> state={m['state']}")
                all_ok = False
        if not all_ok:
            print("\n  ERROR: One or more modules are not in installed state after upgrade.")
            return False
    except Exception as exc:
        print(f"  WARNING: Could not verify post-upgrade state: {exc}")

    print("\nAll modules upgraded successfully.")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Upgrade Odoo modules via XML-RPC")
    parser.add_argument("--url",      default=os.getenv("ODOO_URL"),            help="Odoo URL (e.g. https://zerodowntime.lemacore.com)")
    parser.add_argument("--db",       default=os.getenv("ODOO_DB"),             help="Database name")
    parser.add_argument("--user",     default=os.getenv("ODOO_ADMIN_USER"),     help="Admin username")
    parser.add_argument("--password", default=os.getenv("ODOO_ADMIN_PASSWORD"), help="Admin password")
    parser.add_argument("--modules",  required=True,                            help="Comma-separated module names")
    parser.add_argument("--timeout",  type=int, default=60,                     help="XML-RPC socket timeout in seconds (default: 60)")

    args = parser.parse_args()
    modules = [m.strip() for m in args.modules.split(",") if m.strip()]

    if not all([args.url, args.db, args.user, args.password]):
        print("ERROR: --url, --db, --user, and --password are required (or set via env vars)")
        sys.exit(1)

    if not modules:
        print("ERROR: --modules cannot be empty")
        sys.exit(1)

    success = upgrade_modules(args.url, args.db, args.user, args.password, modules, args.timeout)
    sys.exit(0 if success else 1)
