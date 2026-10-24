# Archaeology Assistant (RS3 Client Plugin)

**Author:** Brad Evans (`bradrevans@gmail.com`)  
**Version:** `0.2.0`  
**Required Dependency:** `PrettyUI` (`6398181`)

An official **RuneScape 3 Client API** plugin (Lua 5.4.8) that scans your inventory for damaged Archaeology artefacts, calculates the restoration materials required, tracks your owned materials across your **Backpack**, **Material Storage**, and **Bank**, and shows your live `Owned / Required` (`x/x`) progress and exact material deficits.

---

## Features (v0.2.0)
- **Complete RS3 Artefact & Material Database**: Includes all 231 damaged artefacts (levels 1–120, including unpowered Tetracompass and Spear of Annihilation) and all 47 Archaeology materials + 22 secondary restoration items.
- **Two Dedicated Views (Tabs)**:
  - **Artefacts Tab**:
    - Scans damaged artefacts across your **Backpack** and **Bank**.
    - Individual **Track** toggles (`On` / `Off`) and **`+` / `-`** quantity overrides per artefact.
    - Displays artefact level, owned quantities (`Bag`, `Bank`, or combined), and live repair status (`Ready`, `X / Y Ready`, `Short (N mats)`, or `Off (Can Repair)`).
    - Summary banner showing total included artefacts, immediately restorable count, total potential Archaeology XP, and Chronotes.
    - **Pin / Lock** button (`Pin` / `Unpin`) to lock your chosen artefact targets so you can bank them and farm materials without losing your plan.
  - **Materials Tab**:
    - Calculates exact restoration materials required based on tracked artefacts.
    - Displays `Material` name, required excavation `Lvl`, material cache / dig site `Location`, `Owned / Req` progress, and `Short` deficit.
    - **Show Filter** toggle (`Show: All` vs. `Short Only`) to focus exclusively on missing items.
- **Native `PrettyUI` Movable, Resizable & Scrollable Window**:
  - Uses `prettyui.Window` (`6398181`) with smooth scrolling, edge/corner resizing, and automatic geometry and visibility persistence in `PersistentDB`.
  - Integrates with the **RS3 Ribbon Bar** (`hasRibbonIcon: true`) so you can show/hide the window anytime from the plugin hub.
  - Clean responsive reflow: expanding the window allocates 100% of extra width to the `Location` column.
- **Sync Status Badges with In-Game Icons & Rich Tooltips**:
  - Compact icon badges in the toolbar for **Material Storage** (Archaeology Journal / Material icon) and **Bank** (Coins pile icon).
  - Hovering displays sync instructions (e.g. opening a workbench, checking Material storage information in your Archaeology journal, or opening your Bank).
  - Status dot indicator and borders:
    - 🟢 **Synced (Green)**: Verified live in the current game session.
    - 🟠 **Cached (Amber)**: Loaded from previous session cache (resync recommended in case items changed on another device).
    - 🔴 **Not Synced (Red)**: Container not yet opened / no data.
    - ⚪ **Ignored (Grey)**: Container excluded by the current `Src` filter mode.
- **Multi-Source Material Tracking (`Src` button)**:
  - Cycle container counting: **Src: All** *(default: Bag + Storage + Bank)*, **Src: Bag+Stor**, **Src: Storage**, **Src: Bag Only**, and **Src: Bag+Bank**.
- **Duplicate Artefacts Inclusion (`Dupes` button)**:
  - Toggle default inclusion between **Dupes: All** and **Dupes: 1x** (or shows **Dupes: Custom** when individual `+`/`-` overrides are active).
- **Porter & Cart Live Tracking**:
  - Detects Sign of the Porter transfers to Material Storage from in-game chat messages, updating material counts and deficits in real time without requiring a reopen.
- **Clean Empty States**:
  - Hides empty tables and reflows window scroll height cleanly when no damaged artefacts are carried or all required materials are ready.

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

