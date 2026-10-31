#!/usr/bin/env python3
"""
Unified cross-platform CLI for managing the Archaeology Assistant project.

Commands:
  python manage.py update-data [--dry-run]
  python manage.py build [--update-data] [--deploy] [--launch-beta]
  python manage.py deploy [--update-data] [--launch-beta]
  python manage.py package [--update-data]
  python manage.py launch-beta
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from build_plugin import run_build  # noqa: E402
from launch_beta import launch_rs3_beta  # noqa: E402
from package_submission import package_submission  # noqa: E402
import update_wiki_data  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Archaeology Assistant project management CLI.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # update-data
    p_update = subparsers.add_parser("update-data", help="Scrape RuneScape Wiki and regenerate data/*.lua")
    p_update.add_argument("--dry-run", action="store_true", help="Fetch and parse without writing files")

    # build
    p_build = subparsers.add_parser("build", help="Validate and stage plugin files into dist/")
    p_build.add_argument("--update-data", action="store_true", help="Refresh Wiki data before building")
    p_build.add_argument("--deploy", action="store_true", help="Deploy to local RS3 plugins folder")
    p_build.add_argument("--deploy-dir", type=Path, default=None, help="Custom deployment directory")
    p_build.add_argument("--launch-beta", action="store_true", help="Launch RS3 Beta client after building")

    # deploy
    p_deploy = subparsers.add_parser("deploy", help="Build, validate, and deploy to local RS3 plugins folder")
    p_deploy.add_argument("--update-data", action="store_true", help="Refresh Wiki data before deploying")
    p_deploy.add_argument("--deploy-dir", type=Path, default=None, help="Custom deployment directory")
    p_deploy.add_argument("--launch-beta", action="store_true", help="Launch RS3 Beta client after deploying")

    # package
    p_pkg = subparsers.add_parser("package", help="Build, validate, and create Mod.io zip archive")
    p_pkg.add_argument("--update-data", action="store_true", help="Refresh Wiki data before packaging")

    # launch-beta
    subparsers.add_parser("launch-beta", help="Launch the RuneScape 3 Plugin Beta client")

    args = parser.parse_args()

    try:
        if args.command == "update-data":
            sys.argv = [sys.argv[0]] + (["--dry-run"] if args.dry_run else [])
            return update_wiki_data.main()
        if args.command == "build":
            run_build(
                update_data=args.update_data,
                deploy=args.deploy,
                deploy_dir=args.deploy_dir,
                launch_beta=args.launch_beta,
            )
            return 0
        if args.command == "deploy":
            run_build(
                update_data=args.update_data,
                deploy=True,
                deploy_dir=args.deploy_dir,
                launch_beta=args.launch_beta,
            )
            return 0
        if args.command == "package":
            package_submission(update_data=args.update_data)
            return 0
        if args.command == "launch-beta":
            launch_rs3_beta()
            return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
