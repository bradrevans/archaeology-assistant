# Archaeology Assistant (RS3 Client Plugin)

**Author:** Brad Evans (`bradrevans@gmail.com`)  
**Version:** `0.2.0`  
**Required Dependency:** `PrettyUI` (`6398181`)

An official **RuneScape 3 Client API** plugin (Lua 5.4.8) that scans your inventory for damaged Archaeology artefacts, calculates the restoration materials required, tracks your owned materials across your **Backpack**, **Material Storage**, and **Bank**, and shows your live `Owned / Required` (`x/x`) progress and exact material deficits.

---

## Features (v0.2.0)
- **Complete RS3 Artefact & Material Database**: Includes all 231 damaged artefacts (levels 1–120, including unpowered Tetracompass and Spear of Annihilation) and all 47 Archaeology materials + 22 secondary restoration items.
- **Native `PrettyUI` Movable, Resizable & Scrollable Window**:
  - Uses `prettyui.Window` (`6398181`) so you can drag the titlebar to move the window anywhere on screen, drag any edge/corner to resize it, and scroll smoothly through all required materials without pagination button clutter.
  - Automatically saves and restores window position, size, and visibility in `PersistentDB`.
  - Integrates with the **RS3 Ribbon Bar** (`hasRibbonIcon: true`) so you can show/hide the window or reset its position anytime from the plugin hub.
- **Live Bank & Material Storage Sync Prompts**:
  - Displays a prominent colour-coded status banner alerting you if your selected material sources (`Material Storage` or `Bank`) have not been opened yet (`! Action Needed: Check Material Storage / Bank`), are using cached counts from a previous session (`Using Cached Counts`), or have been verified live in your current session (`Sources Synced Live`).
- **Multi-Source Material Tracking (`Src` button)**:
  - **Bag + Storage** *(default)*
  - **All (Bag + Storage + Bank)**
  - **Storage Only**
  - **Backpack Only**
  - **Bag + Bank**
- **Include / Exclude Duplicate Artefacts (`Dupes` button)**:
  - Toggle between **Dupes: All** (sums material requirements across all copies of damaged artefacts in your inventory) and **Dupes: 1x** (counts only 1 of each unique damaged artefact).
- **All vs. Short-Only Filter (`Show` button)**:
  - Defaults to showing **all required materials** with `Owned / Required` (`x/x`) and status (`-N short` or `Ready (+N)`), with a single-click toggle to show **Short Only**.
- **Pin / Lock Target List (`Pin` / `Unpin` button)**:
  - Pin your current damaged artefacts so you can deposit the artefacts in your bank, head out to dig sites/caches, and watch your `Owned / Required` (`x/x`) progress update live as you excavate (including Sign of the Porter transfers to Material Storage).
- **Persistent State**: Automatically caches your Material Storage, Bank material counts, pinned artefacts, window geometry, and UI preferences across game sessions via `PersistentDB`.

---

## Project Structure

### Runtime Plugin Files (Bundled into `dist/archaeology-assistant`)
- [`plugin.json`](file:///c:/Users/bradr/code/archaeology-assistant/plugin.json) — RS3 plugin manifest (declares `prettyui: 6398181` dependency and ribbon bar icon)
- [`main.lua`](file:///c:/Users/bradr/code/archaeology-assistant/main.lua) — Plugin entrypoint, event subscriptions, and `PluginShutdown()` persistence hook
- [`tracker.lua`](file:///c:/Users/bradr/code/archaeology-assistant/tracker.lua) — Inventory scanner, material deficit calculator, sync prompt analyzer, and pin/filter state manager
- [`ui/window.lua`](file:///c:/Users/bradr/code/archaeology-assistant/ui/window.lua) — In-game `PrettyUI` movable/resizable/scrollable window, sync prompt banner, responsive material table, and Ribbon Bar hub
- [`data/materials.lua`](file:///c:/Users/bradr/code/archaeology-assistant/data/materials.lua) — Auto-generated Archaeology material metadata and cache locations
- [`data/artefacts.lua`](file:///c:/Users/bradr/code/archaeology-assistant/data/artefacts.lua) — Auto-generated damaged artefact restoration recipes

### Build & Data Generation Scripts (Excluded from Plugin Bundle)
- [`launch-beta.cmd`](file:///c:/Users/bradr/code/archaeology-assistant/launch-beta.cmd) / [`scripts/Launch-Beta.ps1`](file:///c:/Users/bradr/code/archaeology-assistant/scripts/Launch-Beta.ps1) — One-step command (or double-clickable batch file) that builds, deploys to `C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\archaeology-assistant`, syncs the `PrettyUI` (`6398181`) dependency, and launches the RS3 Plugin Developer Beta client via the Jagex Launcher.
- [`deploy.cmd`](file:///c:/Users/bradr/code/archaeology-assistant/deploy.cmd) — Quick command (or double-clickable batch file) to rebuild and deploy updated files while the Beta client is already running.
- [`scripts/Update-WikiData.ps1`](file:///c:/Users/bradr/code/archaeology-assistant/scripts/Update-WikiData.ps1) — Replayable script that fetches live Archaeology materials and artefact tables from the official RuneScape Wiki, validates recipe integrity, and regenerates `data/materials.lua` and `data/artefacts.lua`.
- [`scripts/Build-Plugin.ps1`](file:///c:/Users/bradr/code/archaeology-assistant/scripts/Build-Plugin.ps1) — Validates `plugin.json` and Lua modules, stages a clean runtime-only plugin bundle in `dist/archaeology-assistant` (excluding `scripts/`, `.cmd` files, `README.md`, and git files), deploys to `C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\archaeology-assistant`, and ensures `PrettyUI` (`6398181`) is synced into `RuneScape-BETA\plugins`.

---

## Updating Data, Building & Testing in RS3

### 1. Launch the RS3 Plugin Developer Beta
To build, deploy, and launch the RS3 Plugin Developer Beta client in one step, run (or double-click in File Explorer):
```powershell
.\launch-beta.cmd
```
*(Or to re-deploy code changes while the Beta client is already open, run `.\deploy.cmd`.)*

### 2. Regenerate Artefact & Material Data from the RuneScape Wiki
Whenever RuneScape releases new Archaeology dig sites, artefacts, or materials, run:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Update-WikiData.ps1
```
*(Pass `-DryRun` to fetch and validate Wiki data without overwriting files, or run `.\deploy.cmd -UpdateData` to update data and deploy in one command.)*

### 3. Enable & Reload in the RS3 Beta Client
1. In the Beta lobby, click **Import Save** to copy your live character into the Beta world, then enter the game.
2. Open the RS3 Developer Console (`Alt` + `` ` ``) and run:
   - `prf` — Refresh the plugin list
   - `pon prettyui` — Enable the `PrettyUI` dependency (if not already enabled)
   - `pon archaeology-assistant` — Enable the plugin
   - `prl archaeology-assistant` — Reload the plugin after running `.\deploy.cmd`

