#!/usr/bin/env python3
"""
Cross-platform build, validation, staging, and deployment script for Archaeology Assistant.

Usage:
  python scripts/build_plugin.py [--update-data] [--deploy] [--deploy-dir PATH] [--launch-beta]
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

PLUGIN_SLUG = "archaeology-assistant"
RUNTIME_DIRS = ("core", "data", "ui")
ROOT_RUNTIME_FILES = ("plugin.json", "main.lua", "tracker.lua")


def resolve_default_deploy_dirs() -> list[Path]:
    """Resolves the default RS3 Lua dev_plugins directories across Windows, macOS, and Linux."""
    env_override = os.environ.get("RS3_PLUGIN_DIR")
    if env_override:
        return [Path(env_override) / PLUGIN_SLUG]

    sys_name = platform.system().lower()
    if sys_name == "windows":
        prog_data = Path(os.environ.get("ProgramData", r"C:\ProgramData"))
        return [
            prog_data / "Jagex" / "RuneScape-BETA" / "dev_plugins" / PLUGIN_SLUG,
            prog_data / "Jagex" / "RuneScape" / "dev_plugins" / PLUGIN_SLUG,
        ]
    if sys_name == "darwin":
        base = Path.home() / "Library" / "Application Support" / "Jagex"
        return [
            base / "RuneScape-BETA" / "dev_plugins" / PLUGIN_SLUG,
            base / "RuneScape" / "dev_plugins" / PLUGIN_SLUG,
        ]
    base = Path.home() / ".local" / "share" / "Jagex"
    return [
        base / "RuneScape-BETA" / "dev_plugins" / PLUGIN_SLUG,
        base / "RuneScape" / "dev_plugins" / PLUGIN_SLUG,
    ]


def collect_runtime_files(repo_root: Path) -> list[str]:
    """Discovers all runtime files to validate, stage, and package."""
    rel_files: list[str] = list(ROOT_RUNTIME_FILES)
    for sub in RUNTIME_DIRS:
        sub_dir = repo_root / sub
        if sub_dir.is_dir():
            for lua_file in sorted(sub_dir.glob("*.lua")):
                rel_files.append(f"{sub}/{lua_file.name}")
    return rel_files


def validate_plugin_manifest(repo_root: Path) -> dict[str, str]:
    manifest_path = repo_root / "plugin.json"
    if not manifest_path.is_file():
        raise RuntimeError("Missing plugin.json")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for key in ("name", "version", "contactEmailAddress"):
        val = str(manifest.get(key, "")).strip()
        if not val:
            raise RuntimeError(f"plugin.json is missing required field '{key}'")

    entry = manifest.get("entry")
    if entry and entry != "main.lua":
        raise RuntimeError(f"plugin.json 'entry' must be 'main.lua' (found '{entry}')")

    print(f"      -> Plugin: {manifest['name']} v{manifest['version']} ({manifest['contactEmailAddress']})")
    return manifest


def validate_lua_files_and_requires(repo_root: Path, rel_files: list[str]) -> None:
    for rel in rel_files:
        full_path = repo_root / rel
        if not full_path.is_file():
            raise RuntimeError(f"Missing required plugin file: {rel}")

        raw_bytes = full_path.read_bytes()
        if raw_bytes.startswith(b"\xef\xbb\xbf"):
            # Strip UTF-8 BOM automatically to keep RS3 Lua loader happy
            text = raw_bytes[3:].decode("utf-8")
            full_path.write_text(text, encoding="utf-8", newline="\n")
        else:
            text = raw_bytes.decode("utf-8")

        if rel.endswith(".lua"):
            open_braces = text.count("{")
            close_braces = text.count("}")
            if open_braces != close_braces:
                raise RuntimeError(
                    f"Unbalanced braces '{{' ({open_braces}) vs '}}' ({close_braces}) in {rel}"
                )

            # Verify all local module require("...") paths exist
            for req_mod in re.findall(r'require\(\s*["\']([^"\']+)["\']\s*\)', text):
                target_lua = repo_root / f"{req_mod}.lua"
                if not target_lua.is_file():
                    raise RuntimeError(f"{rel} requires '{req_mod}', but {req_mod}.lua does not exist")


def validate_data_integrity(repo_root: Path) -> None:
    mats_path = repo_root / "data" / "materials.lua"
    arts_path = repo_root / "data" / "artefacts.lua"
    cols_path = repo_root / "data" / "collections.lua"
    spots_path = repo_root / "data" / "hotspots.lua"

    mats_content = mats_path.read_text(encoding="utf-8")
    arts_content = arts_path.read_text(encoding="utf-8")
    cols_content = cols_path.read_text(encoding="utf-8")
    spots_content = spots_path.read_text(encoding="utf-8")

    # 1. Check defined materials vs recipe materials
    defined_mats = {
        m.group(1)
        for m in re.finditer(r'name\s*=\s*"([^"]+)",\s*level\s*=', mats_content)
    }
    recipe_mats = {
        m.group(1)
        for m in re.finditer(r'\{\s*name\s*=\s*"([^"]+)",\s*count\s*=\s*\d+\s*\}', arts_content)
    }
    missing_mats = sorted(recipe_mats - defined_mats)
    if missing_mats:
        raise RuntimeError(
            "Artefact recipes reference materials missing from data/materials.lua: "
            + ", ".join(missing_mats)
        )

    # 2. Check defined artefacts vs collection artefacts
    defined_arts = {
        m.group(1)
        for m in re.finditer(r'(?m)^\s*name\s*=\s*"([^"]+)",\s*$', arts_content)
    }
    col_art_blocks = re.findall(r"artefacts\s*=\s*\{([^}]+)\}", cols_content)
    col_arts: set[str] = set()
    for block in col_art_blocks:
        for m in re.finditer(r'"([^"]+)"', block):
            col_arts.add(m.group(1))
    missing_col_arts = sorted(col_arts - defined_arts)
    if missing_col_arts:
        raise RuntimeError(
            "Collections reference artefacts missing from data/artefacts.lua: "
            + ", ".join(missing_col_arts)
        )

    # 3. Check for unescaped HTML entities across all data files
    for data_name, content in (
        ("data/materials.lua", mats_content),
        ("data/artefacts.lua", arts_content),
        ("data/collections.lua", cols_content),
        ("data/hotspots.lua", spots_content),
    ):
        if re.search(r"&#\d+;|&nbsp;|&amp;", content):
            raise RuntimeError(f"Unescaped HTML entities found in {data_name}")

    print(
        f"      -> Verified {len(defined_mats)} materials, {len(defined_arts)} artefacts, "
        f"and {len(col_art_blocks)} collections."
    )


def stage_bundle(repo_root: Path, rel_files: list[str]) -> Path:
    dist_dir = repo_root / "dist" / PLUGIN_SLUG
    if dist_dir.exists():
        shutil.rmtree(dist_dir)
    dist_dir.mkdir(parents=True, exist_ok=True)

    for rel in rel_files:
        src = repo_root / rel
        dst = dist_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

    print(f"      -> Staged {len(rel_files)} files to: {dist_dir}")
    return dist_dir


def deploy_bundle(dist_dir: Path, deploy_dirs: list[Path], rel_files: list[str]) -> None:
    for deploy_dir in deploy_dirs:
        print(f"[Deploy] Copying plugin files to: {deploy_dir}")
        if deploy_dir.exists():
            # Clean existing subdirectories so stale files do not linger
            for sub in RUNTIME_DIRS:
                sub_target = deploy_dir / sub
                if sub_target.exists():
                    shutil.rmtree(sub_target)
        deploy_dir.mkdir(parents=True, exist_ok=True)

        for rel in rel_files:
            src = dist_dir / rel
            dst = deploy_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

    # Ensure PrettyUI (6398181) is unpacked into dev_plugins/prettyui so local dependency resolves
    if platform.system().lower() == "windows":
        prog_data = Path(os.environ.get("ProgramData", r"C:\ProgramData"))
        pretty_zips = [
            prog_data / "Jagex" / "RuneScape-BETA" / "plugins" / "6398181" / "6398181.zip",
            prog_data / "Jagex" / "RuneScape" / "plugins" / "6398181" / "6398181.zip",
        ]
        found_zip = next((z for z in pretty_zips if z.is_file()), None)
        if found_zip:
            for deploy_dir in deploy_dirs:
                dev_pretty_dir = deploy_dir.parent / "prettyui"
                if not (dev_pretty_dir / "main.lua").is_file():
                    dev_pretty_dir.mkdir(parents=True, exist_ok=True)
                    with zipfile.ZipFile(found_zip, "r") as zf:
                        zf.extractall(dev_pretty_dir)
                    print(f"[Deploy] Unpacked PrettyUI dependency to: {dev_pretty_dir}")

    print("[Deploy] Successfully deployed to RS3 dev_plugins.")


def run_build(
    update_data: bool = False,
    deploy: bool = False,
    deploy_dir: Path | None = None,
    launch_beta: bool = False,
) -> tuple[dict[str, str], Path, list[str]]:
    repo_root = Path(__file__).resolve().parent.parent

    if update_data:
        print("[Pre-Build] Updating Wiki data...")
        updater = repo_root / "scripts" / "update_wiki_data.py"
        res = subprocess.run([sys.executable, str(updater)], check=False)
        if res.returncode != 0:
            raise RuntimeError("Wiki data update failed.")

    print("[1/3] Validating plugin.json & Lua module graph...")
    rel_files = collect_runtime_files(repo_root)
    manifest = validate_plugin_manifest(repo_root)
    validate_lua_files_and_requires(repo_root, rel_files)

    print("[2/3] Validating Archaeology data integrity...")
    validate_data_integrity(repo_root)

    print("[3/3] Staging clean distribution bundle...")
    dist_dir = stage_bundle(repo_root, rel_files)

    if deploy:
        target_dirs = [deploy_dir] if deploy_dir else resolve_default_deploy_dirs()
        deploy_bundle(dist_dir, target_dirs, rel_files)

    if launch_beta:
        from launch_beta import launch_rs3_beta
        launch_rs3_beta()

    print("\nBuild & validation succeeded!")
    return manifest, dist_dir, rel_files


def main() -> int:
    parser = argparse.ArgumentParser(description="Build, validate, and optionally deploy Archaeology Assistant.")
    parser.add_argument("--update-data", action="store_true", help="Refresh Wiki data before building.")
    parser.add_argument("--deploy", action="store_true", help="Copy built files to local RS3 plugins folder.")
    parser.add_argument("--deploy-dir", type=Path, default=None, help="Custom RS3 plugin deployment directory.")
    parser.add_argument("--launch-beta", action="store_true", help="Launch RS3 Plugin Beta client after build.")
    args = parser.parse_args()

    try:
        run_build(
            update_data=args.update_data,
            deploy=args.deploy,
            deploy_dir=args.deploy_dir,
            launch_beta=args.launch_beta,
        )
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
