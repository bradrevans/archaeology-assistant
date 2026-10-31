#!/usr/bin/env python3
"""
Cross-platform Mod.io submission packager for Archaeology Assistant.

Creates `dist/archaeology-assistant-v<version>.zip` with forward-slash relative paths
and root-level `main.lua` and `plugin.json` as required by the Jagex / Mod.io scanner.

Usage:
  python scripts/package_submission.py [--update-data]
"""

from __future__ import annotations

import argparse
import sys
import zipfile
from pathlib import Path

from build_plugin import PLUGIN_SLUG, run_build


def package_submission(update_data: bool = False) -> Path:
    manifest, dist_dir, rel_files = run_build(update_data=update_data)
    version = str(manifest["version"]).strip()

    out_root = dist_dir.parent
    zip_path = out_root / f"{PLUGIN_SLUG}-v{version}.zip"

    # Remove any old zip files in dist/
    for old_zip in out_root.glob(f"{PLUGIN_SLUG}*.zip"):
        old_zip.unlink()

    with zipfile.ZipFile(zip_path, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for rel in rel_files:
            file_path = dist_dir / rel
            if not file_path.is_file():
                raise RuntimeError(f"Expected staged file missing: {file_path}")
            arcname = rel.replace("\\", "/")
            zf.write(file_path, arcname=arcname)

    # Verify archive structure for Mod.io scanner compatibility
    with zipfile.ZipFile(zip_path, mode="r") as zf:
        entries = set(zf.namelist())
        if "main.lua" not in entries or "plugin.json" not in entries:
            raise RuntimeError("Archive is missing root-level main.lua or plugin.json")
        for entry in entries:
            if "\\" in entry:
                raise RuntimeError(f"Archive contains backslash path separator: {entry}")

    size_kb = zip_path.stat().st_size / 1024.0
    print("\n============================================================")
    print(" Mod.io Submission Package Ready!")
    print("============================================================")
    print(f" -> Package: {zip_path} ({size_kb:.1f} KB, {len(rel_files)} files)")
    return zip_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Package Archaeology Assistant into a Mod.io submission zip.")
    parser.add_argument("--update-data", action="store_true", help="Refresh Wiki data before packaging.")
    args = parser.parse_args()

    try:
        package_submission(update_data=args.update_data)
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
