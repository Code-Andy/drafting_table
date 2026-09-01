#!/usr/bin/env python3
"""Generate a small AltStore/SideStore-compatible source JSON.

This only writes public metadata; it never reads credentials or signs an IPA.
The caller must provide the final, publicly reachable IPA URL so the generated
feed cannot accidentally point SideStore at a local/temporary file.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
from datetime import datetime, timezone
from urllib.parse import urlparse


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--ipa-url", required=True, help="HTTPS URL where the IPA is hosted")
    parser.add_argument("--name", default="Drafting Table")
    parser.add_argument("--bundle-id", default="com.yourname.draftingtable")
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--build-version", default="1", help="CFBundleVersion")
    parser.add_argument("--developer", default="Drafting Table contributors")
    parser.add_argument("--description", default="Engineering sketching for iPad.")
    parser.add_argument("--icon-url", required=True, help="HTTPS URL for the app icon")
    parser.add_argument("--source-identifier", default=None)
    parser.add_argument("--ipa-path", type=pathlib.Path, required=True)
    parser.add_argument("--min-os-version", default="18.0")
    parser.add_argument("--version-date", default=None, help="ISO-8601 date; defaults to current UTC")
    return parser.parse_args()


def validate_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("error: --ipa-url must be an absolute HTTPS URL")
    return value


def main() -> int:
    args = parse_args()
    validate_url(args.ipa_url)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", args.bundle_id):
        raise SystemExit("error: --bundle-id must look like a reverse-DNS identifier")
    validate_url(args.icon_url)
    if not args.ipa_path.is_file():
        raise SystemExit(f"error: --ipa-path does not exist: {args.ipa_path}")

    date = args.version_date or datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    version = {
        "version": args.version,
        "buildVersion": args.build_version,
        "date": date,
        "downloadURL": args.ipa_url,
        "size": args.ipa_path.stat().st_size,
        "sha256": hashlib.sha256(args.ipa_path.read_bytes()).hexdigest(),
        "minOSVersion": args.min_os_version,
    }

    app = {
        "name": args.name,
        "bundleIdentifier": args.bundle_id,
        "developerName": args.developer,
        "localizedDescription": args.description,
        "iconURL": args.icon_url,
        "versions": [version],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }

    source = {
        "name": args.name,
        "apps": [app],
    }
    if args.source_identifier:
        source["identifier"] = args.source_identifier
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote AltStore source for {args.bundle_id} {args.version} -> {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
