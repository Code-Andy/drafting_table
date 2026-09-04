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
import plistlib
import zipfile
from datetime import datetime, timezone
from typing import Dict, Optional
from urllib.parse import urlparse


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--ipa-url", required=True, help="HTTPS URL where the IPA is hosted")
    parser.add_argument("--name", default=None, help="Display name (defaults to the IPA's Info.plist)")
    parser.add_argument("--bundle-id", default=None, help="Bundle identifier (defaults to the IPA's Info.plist)")
    parser.add_argument("--version", default=None, help="CFBundleShortVersionString (defaults to the IPA)")
    parser.add_argument("--build-version", default=None, help="CFBundleVersion (defaults to the IPA)")
    parser.add_argument("--developer", default="Drafting Table contributors")
    parser.add_argument("--description", default="Engineering sketching for iPad.")
    parser.add_argument("--icon-url", required=True, help="HTTPS URL for the app icon")
    parser.add_argument("--source-identifier", default=None)
    parser.add_argument("--ipa-path", type=pathlib.Path, required=True)
    parser.add_argument("--min-os-version", default=None, help="MinimumOSVersion (defaults to the IPA)")
    parser.add_argument("--version-date", default=None, help="ISO-8601 date; defaults to current UTC")
    return parser.parse_args()


def validate_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("error: --ipa-url must be an absolute HTTPS URL")
    return value


def read_ipa_plist(ipa_path: pathlib.Path) -> Dict[str, object]:
    """Read the one application Info.plist from an IPA archive.

    The feed must describe the artifact being published. Requiring callers to
    repeat version and bundle values has caused stale AltStore feeds in the
    past, so these values now come from the IPA and optional flags are only
    accepted when they match.
    """
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            plist_names = sorted(
                name
                for name in archive.namelist()
                if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)
            )
            if len(plist_names) != 1:
                raise SystemExit(
                    "error: IPA must contain exactly one Payload/*.app/Info.plist "
                    f"(found {len(plist_names)})"
                )
            try:
                value = plistlib.loads(archive.read(plist_names[0]))
            except (OSError, plistlib.InvalidFileException) as exc:
                raise SystemExit(f"error: unable to parse {plist_names[0]}: {exc}") from exc
    except (OSError, zipfile.BadZipFile) as exc:
        raise SystemExit(f"error: unable to read IPA {ipa_path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit("error: app Info.plist is not a dictionary")
    return value


def plist_string(plist: Dict[str, object], key: str) -> str:
    value = plist.get(key)
    if not isinstance(value, (str, int, float)) or not str(value):
        raise SystemExit(f"error: IPA Info.plist has no usable {key}")
    return str(value)


def select_metadata(label: str, requested: Optional[str], actual: str) -> str:
    if requested is not None and requested != actual:
        raise SystemExit(
            f"error: --{label} does not match IPA Info.plist "
            f"(expected '{actual}', got '{requested}')"
        )
    return actual


def main() -> int:
    args = parse_args()
    validate_url(args.ipa_url)
    validate_url(args.icon_url)
    if not args.ipa_path.is_file():
        raise SystemExit(f"error: --ipa-path does not exist: {args.ipa_path}")

    plist = read_ipa_plist(args.ipa_path)
    actual_bundle_id = plist_string(plist, "CFBundleIdentifier")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", actual_bundle_id):
        raise SystemExit("error: IPA CFBundleIdentifier must look like a reverse-DNS identifier")
    bundle_id = select_metadata("bundle-id", args.bundle_id, actual_bundle_id)
    version_value = select_metadata(
        "version", args.version, plist_string(plist, "CFBundleShortVersionString")
    )
    build_version = select_metadata(
        "build-version", args.build_version, plist_string(plist, "CFBundleVersion")
    )
    min_os_version = select_metadata(
        "min-os-version", args.min_os_version, plist_string(plist, "MinimumOSVersion")
    )
    display_name = args.name or str(plist.get("CFBundleDisplayName") or plist.get("CFBundleName") or "Drafting Table")

    date = args.version_date or datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    version_entry = {
        "version": version_value,
        "buildVersion": build_version,
        "date": date,
        "downloadURL": args.ipa_url,
        "size": args.ipa_path.stat().st_size,
        "sha256": hashlib.sha256(args.ipa_path.read_bytes()).hexdigest(),
        "minOSVersion": min_os_version,
    }

    app = {
        "name": display_name,
        "bundleIdentifier": bundle_id,
        "developerName": args.developer,
        "localizedDescription": args.description,
        "iconURL": args.icon_url,
        "versions": [version_entry],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }

    source = {
        "name": display_name,
        "apps": [app],
    }
    if args.source_identifier:
        source["identifier"] = args.source_identifier
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote AltStore source for {bundle_id} {version_value} -> {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
