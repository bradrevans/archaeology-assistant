#!/usr/bin/env python3
"""
Cross-platform launcher for the RuneScape 3 Plugin Beta client (`rs-launch://...`).

Usage:
  python scripts/launch_beta.py
"""

from __future__ import annotations

import os
import platform
import subprocess
import sys
import webbrowser

BETA_URI = "rs-launch://www.runescape.com/k=5/l=$(Language:0)/jav_config_beta.ws"


def launch_rs3_beta() -> None:
    print(f"Launching RuneScape 3 Plugin Beta Client ({BETA_URI})...")
    sys_name = platform.system().lower()
    if sys_name == "windows":
        os.startfile(BETA_URI)  # type: ignore[attr-defined]
    elif sys_name == "darwin":
        subprocess.run(["open", BETA_URI], check=False)
    else:
        if subprocess.run(["xdg-open", BETA_URI], check=False).returncode != 0:
            webbrowser.open(BETA_URI)


def main() -> int:
    try:
        launch_rs3_beta()
        return 0
    except Exception as exc:
        print(f"[ERROR] Failed to launch RS3 Beta URI: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
