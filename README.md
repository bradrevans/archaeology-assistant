# Archaeology Assistant (RS3 Client Plugin)

**Author:** Brad Evans  
**Required Dependency:** `PrettyUI` (`6398181`)

An official **RuneScape 3 Client API** plugin (Lua 5.4.8) that scans your inventory for damaged Archaeology artefacts, calculates the restoration materials required, tracks your owned materials across your **Backpack**, **Material Storage**, and **Bank**, and shows your live `Owned / Required` (`x/x`) progress, exact material deficits, and 3D world excavation spot indicators.

---

## Plugin Features
- **Complete Auto-Scraped RS3 Artefact, Material & Collection Database**:
  - Dynamically generated from the official RuneScape Wiki (`scripts/update_wiki_data.py`), including all 231 damaged artefacts (levels 1–120), all 47 Archaeology materials + 22 secondary items, all 103 excavation hotspots, and all 79 collector Collections with collector NPC locations, achievement IDs, and relic/weapon/mystery reward classifications.
- **Three Dedicated Views (Tabs)**:
  - **Collections Tab (First)**:
    - Lists all 79 RS3 Archaeology collections with required levels, collector NPCs, and required artefacts.
    - **Account Benefits & Relic Powers Highlighted**: Highlights critical unlocks with visual tags and distinct styling under the **Reward** column:
      - **Relic / Monolith Powers** in Cyan (e.g. `Font of Life (+500 Max LP)`, `Pouch Protector`, `Death Ward`, `Inspire Genius`, `Inspire Love`, `Inspire Effort`, `Inspire Awe`, `Nexus Mod`).
      - **T97 Weapon Components** in Gold (e.g. `Inquisitor staff piece`).
      - **Mystery & Blueprint Unlocks** in Amber (e.g. `Howl's Thinking Cap`, `Koschei's needle`).
      - **Repeatable Tetracompass Farming** in Cream (e.g. Green Gobbo Goodies, Red Rum Relics, Zarosian, Guthixian).
    - **Current-Run Repeatable Submission Sync**: For repeatable collections (like Red Rum Relics I or Green Gobbo Goodies), completed achievements in the past do not assume subsequent runs are complete. The plugin tracks which artefacts have been handed in for the *current run*, syncing automatically when checking the Collector Information noticeboard (Interface 657), accessing collector information via your Archaeology journal, or handing in artefacts directly to collectors in dialogue. Once a collection is completed, previously submitted artefacts automatically reset back to 0 progress for the next run.
    - **Per-Collector Sync Tracking (`Collectors: X/13`)**: Dedicated toolbar badge on the Collections tab showing live sync status across all 13 noticeboard collectors. Hovering reveals an organized checklist of every collector with colour-coded sync states (green for synced, red for unsynced) and clear guidance on how to sync via the noticeboard or Archaeology journal.
    - **Dynamic Collection Resizing**: 100% of window resize width expansion is allocated to the **Collection** column so collection names are never truncated.
    - **Progress Column & Artefact Distinction**: Shows live completion progress as `X / Y` (handed in + restored + damaged out of total required). Previously submitted items are displayed in distinct **Cyan** in the collection tooltip alongside exact Bag and Bank locations for restored and damaged pieces.
    - **Multi-Collection Tracking ("Collection-Level Pinning")**:
      - Click `Track` on any collection to track it; track multiple collections simultaneously.
      - Automatically sets required artefact targets and scales required restoration materials and deficits in the Materials tab (excluding any artefacts already submitted to collectors).
      - Excavating duplicate damaged artefacts for a tracked collection does not inflate your target repair count beyond what the collection needs.
      - Displays tracked collection tags on artefacts in the Artefacts tab.
    - **Clean Tooltip Inspection**: Hovering any collection shows the collector's exact hand-in location across Gielinor, account benefits, recurring rewards, chronotes, and a concise checklist of every required artefact with its live status (`Handed in to collector`, `Restored (in Bag/Bank)`, `Damaged (in Bag/Bank)`, `Missing`).
    - **Filter & Management**: Toolbar controls positioned cleanly: `Src`, `Col` filter (`Show: All`, `Incomplete`, `Targeted`, `Powers/Relics`, `Tetra Pieces`, `Unsynced`), `Clear Tracked`, and `Collectors: X/13`.
    - **Targeted Collections Total Chronotes Bounty**: Displays the combined total Chronote payout across all currently targeted collections directly on the Collections tab header (`Collections (X | +Y)`).
  - **Artefacts Tab (Second)**:
    - Scans damaged artefacts across your **Backpack** and **Bank**, including uncollected artefacts targeted by collections.
    - **Artefact Ownership Required for Ready Status**: An artefact requires actual damaged artefact ownership to be marked "Ready". If an artefact is required for a tracked collection but not yet excavated (`Owned: 0`), its status clearly displays `Need Art` (when materials are satisfied) or `Short (Art+Mats)` (when materials are also missing).
    - **Wider Status Column (110px)**: Comfortably fits all detailed statuses (`Short (Art+Mats)`, `Need Art`, `Ready (X/Y)`, `0 (Can Repair)`, `Short (N mats)`) without clipping.
    - **Uncollected Artefact Display & Recipe Deficits**: When collections are tracked, uncollected artefacts are displayed alongside owned artefacts, and their complete restoration materials are added to the Materials tab deficit calculations.
    - **Location Column**: Displays the excavation hotspot and dig site for every artefact (e.g. `Venator remains (Kharid-et)`), with dynamic width expansion on resize.
    - **Artefact Source Filtering**: Dedicated toolbar filter button (`Show: All`, `Show: Tracked`, `Show: Owned`) to instantly isolate artefacts needed for your tracked collections.
    - Displays in-game item icons alongside artefact names.
    - Hovering any row displays a rich floating tooltip with an enlarged (32x32) in-game item sprite, location, restoration XP, Chronotes, targeted collection sources, and the complete materials recipe with live `owned / required` quantities scaled to your target count.
    - Direct **Include** quantity controls (**`+` / `-`** steppers, with `0` cleanly excluding an artefact from material calculations).
    - **Flexible Inclusion Modes (`Dupes` button)**: Cycle between **Dupes: All**, **Dupes: 1x**, and **Include: 0** (sets all includes to 0 across the board for selective single-artefact repairs). Switching back to `All` or `1x` cleanly re-includes previously excluded artefacts.
    - Summary banner showing total included artefacts, immediately restorable count, total potential Archaeology XP, and Chronotes.
    - **Pin / Lock** button (`Pin` / `Unpin`) to lock your chosen artefact targets so you can bank them and farm materials without losing your plan.
  - **Materials Tab (Third)**:
    - Calculates exact restoration materials required based on tracked artefacts and targeted collections.
    - Displays in-game item icons alongside material names.
    - Hovering any row displays a rich floating tooltip with an enlarged (32x32) in-game item sprite, exact container breakdown (`Bag`, `Storage`, `Bank`), total deficit, and all known excavation cache / dig site locations.
    - Displays required excavation `Lvl`, material cache / dig site `Location`, `Owned / Req` progress, and `Short` deficit.
    - **Show Filter** toggle (`Show: All` vs. `Short Only`) to focus exclusively on missing items.
    - **Excavation Spot Highlighter** toggle (`Spots: On` vs. `Spots: Off`) to highlight world spots in 3D space.
- **In-Game Excavation Spot Highlighting & Overhead Deficit Indicators (Artefacts & Materials)**:
  - Scans nearby active world objects (`LocList`) for **Material Caches** (`Material cache (...)`) and all 103 **Excavation Hotspots** yielding materials or artefacts you currently need.
  - **Shows Needed Artefacts Overhead by Name**: If an excavation hotspot yields an artefact required for your tracked collections or inclusion plan, and you do not already have enough damaged or repaired copies, the artefact appears directly on the overhead badge with its in-game item icon and cyan label displaying the artefact name (e.g. `x1 Venator dagger`).
  - **Visually Unique Styling**: Hotspots yielding needed artefacts feature a distinct, vibrant **Cyan** border and downward pointer chevron so you can identify needed artefact spots across the dig site at a glance.
  - Overhead indicators display each obtainable needed material with its in-game item sprite, live deficit quantity, and percentage likelihood based on the spot's material pool (e.g. `100%` for material caches, `25%` for 4-material hotspots).
  - **Proximity-Prioritized Indicators**: Nearby excavation spots and material caches are continuously sorted by distance to the player (`distSq`), guaranteeing that the closest spots always take priority for overhead badge rendering.
  - **Dynamic Real-Time Dismissal ("until they're gone")**: As you collect materials (via inventory updates or Sign of the Porter cart transfers) or excavate damaged artefacts, required counts decrease in real time; once all needed items from a spot are satisfied, the indicator and highlight vanish automatically.
  - **Zero-Stutter Performance Architecture**: Fast-path stationary caching bypasses world object searches when standing still excavating, background logic callbacks are throttled, and projection helpers avoid per-frame GC allocations for smooth 60 FPS gameplay.
  - Fully click-through: does not block interaction with the world or the excavation spot.
- **Porter, Cart & Area Loot Handling**:
  - Automatically retains gathered material progress when depositing via **Material Carts**, Bank Deposit Boxes, or bank chests without requiring a manual Material Storage resync.
  - Automatically credits Sign of the Porter / Grace of the Elves transfers to Material Storage in real time via client chat event handling (`chatAccess` permission).
  - Correctly distinguishes material deposits from dropping items (MiniMenu `Drop` action decreases owned counts naturally) and artefact restoration (where required materials are consumed).
  - Area Loot, dialogue containers, and restoration recipe inspection windows are strictly isolated and never overwrite storage cache or reset tracker state.

---

## Architecture & Project Structure

The codebase follows **SOLID** and **DRY** principles with small, single-responsibility modules organized into `core/`, `data/`, and `ui/`.

### Runtime Plugin Files (Bundled into `dist/archaeology-assistant`)
- [`plugin.json`](file:///c:/Users/bradr/code/archaeology-assistant/plugin.json) — RS3 plugin manifest (declares `prettyui: 6398181` dependency, `chatAccess` permission, and ribbon bar icon)
- [`main.lua`](file:///c:/Users/bradr/code/archaeology-assistant/main.lua) — Plugin entrypoint, event subscriptions, and `PluginShutdown()` persistence hook
- [`tracker.lua`](file:///c:/Users/bradr/code/archaeology-assistant/tracker.lua) — State coordinator for source modes, filters, collection progress, and material/artefact deficit calculations
- **`core/` — Single-Responsibility Domain & Infrastructure Modules**:
  - [`core/utils.lua`](file:///c:/Users/bradr/code/archaeology-assistant/core/utils.lua) — Shared string normalization, HTML/colour tag stripping, number formatting, and table helpers
  - [`core/db.lua`](file:///c:/Users/bradr/code/archaeology-assistant/core/db.lua) — Safe `PersistentDB` wrapper and deterministic map/set/submission serializers
  - [`core/inventory_scanner.lua`](file:///c:/Users/bradr/code/archaeology-assistant/core/inventory_scanner.lua) — Backpack, Bank, and Material Storage scanner with Area Loot and recipe preview isolation
  - [`core/noticeboard_scanner.lua`](file:///c:/Users/bradr/code/archaeology-assistant/core/noticeboard_scanner.lua) — Interface 657 Collector Information noticeboard scanner and `config.Achievement` sync engine
  - [`core/chat_parser.lua`](file:///c:/Users/bradr/code/archaeology-assistant/core/chat_parser.lua) — Sign of the Porter, Grace of the Elves, collector hand-in, and excavation discovery chat parser
- **`data/` — Auto-Generated RuneScape Wiki Data Modules**:
  - [`data/materials.lua`](file:///c:/Users/bradr/code/archaeology-assistant/data/materials.lua) — Auto-generated Archaeology material metadata, IDs, and cache locations
  - [`data/artefacts.lua`](file:///c:/Users/bradr/code/archaeology-assistant/data/artefacts.lua) — Auto-generated damaged artefact restoration recipes, IDs, XP, Chronotes, and hotspot locations
  - [`data/hotspots.lua`](file:///c:/Users/bradr/code/archaeology-assistant/data/hotspots.lua) — Auto-generated database mapping all 103 RS3 Excavation Hotspots to their yielded materials
  - [`data/collections.lua`](file:///c:/Users/bradr/code/archaeology-assistant/data/collections.lua) — Auto-generated database mapping all 79 RS3 Archaeology collections, collector hand-in locations, achievement IDs, required artefacts, and rewards
- **`ui/` — Modular PrettyUI Components**:
  - [`ui/theme.lua`](file:///c:/Users/bradr/code/archaeology-assistant/ui/theme.lua) — Shared colour palette, layout constants, font resolution, and text wrapping height measurement
  - [`ui/tooltip.lua`](file:///c:/Users/bradr/code/archaeology-assistant/ui/tooltip.lua) — Floating tooltip component and tooltip content builders for collections, artefacts, materials, and sync badges
  - [`ui/widgets.lua`](file:///c:/Users/bradr/code/archaeology-assistant/ui/widgets.lua) — Reusable UI component factories (toolbar buttons, sync badges, collector sync pill, table rows, resize handles)
  - [`ui/window.lua`](file:///c:/Users/bradr/code/archaeology-assistant/ui/window.lua) — Main `PrettyUI` movable, resizable, scrollable 3-tab window and Ribbon Bar hub
  - [`ui/overlay.lua`](file:///c:/Users/bradr/code/archaeology-assistant/ui/overlay.lua) — In-game 3D world spot highlighter and overhead deficit indicator badges

### Cross-Platform Python Toolchain (Excluded from Plugin Bundle)
All build, Wiki data scraping, validation, deployment, and Mod.io packaging tasks are written in standard-library **Python 3.10+** (`manage.py` and `scripts/*.py`) so they run identically on **Windows, macOS, and Linux** without external pip dependencies:
- [`manage.py`](file:///c:/Users/bradr/code/archaeology-assistant/manage.py) — Unified cross-platform CLI entrypoint (`update-data`, `build`, `deploy`, `package`, `launch-beta`)
- [`scripts/update_wiki_data.py`](file:///c:/Users/bradr/code/archaeology-assistant/scripts/update_wiki_data.py) — Scrapes live Archaeology materials, artefacts, excavation hotspots, relic powers, collections, achievement IDs, and collector NPC locations from `https://runescape.wiki` and regenerates `data/*.lua`
- [`scripts/build_plugin.py`](file:///c:/Users/bradr/code/archaeology-assistant/scripts/build_plugin.py) — Validates `plugin.json`, Lua syntax/brace balance, local `require(...)` graph, and data integrity, then stages the runtime bundle in `dist/archaeology-assistant/` (and optionally deploys to the local RS3 plugin directory)
- [`scripts/package_submission.py`](file:///c:/Users/bradr/code/archaeology-assistant/scripts/package_submission.py) — Runs the full build validation and packages `dist/archaeology-assistant-v<version>.zip` with root-level `main.lua` and `plugin.json` for Mod.io
- [`scripts/launch_beta.py`](file:///c:/Users/bradr/code/archaeology-assistant/scripts/launch_beta.py) — Builds, deploys, and opens the `rs-launch://` URI via the OS URL handler
- [`deploy.cmd`](file:///c:/Users/bradr/code/archaeology-assistant/deploy.cmd), [`package.cmd`](file:///c:/Users/bradr/code/archaeology-assistant/package.cmd), [`launch-beta.cmd`](file:///c:/Users/bradr/code/archaeology-assistant/launch-beta.cmd) — Convenience Windows batch wrappers that invoke `manage.py`

---

## Developer Workflow: Updating Data, Building & Packaging

### Prerequisites
- **Python 3.10+** (no third-party packages required; uses only Python's standard library).

### 1. Regenerate Artefact, Material & Collection Data from the RuneScape Wiki
Whenever RuneScape releases new Archaeology dig sites, artefacts, materials, or collections, run:
```bash
python manage.py update-data
```
*(Pass `--dry-run` to fetch and validate Wiki data without writing files.)*

### 2. Validate & Build the Runtime Plugin Bundle
To validate `plugin.json`, Lua module imports, and data cross-references and stage the clean bundle in `dist/archaeology-assistant/`:
```bash
python manage.py build
```

### 3. Deploy Locally to the RS3 Client
To build and copy the staged files directly into your local RS3 `dev_plugins/archaeology-assistant` directories (`RuneScape-BETA\dev_plugins` and `RuneScape\dev_plugins`):
```bash
python manage.py deploy
```
*(On Windows, you can also double-click `deploy.cmd`, or run `python manage.py deploy --update-data` to refresh Wiki data and deploy in one command.)*

### 4. Package for Mod.io Submission
To generate a clean, validated submission archive ready for upload to [Mod.io](https://mod.io/g/runescape):
```bash
python manage.py package
```
*(On Windows, you can also double-click `package.cmd`.)*  
This command:
1. Validates `plugin.json` fields, manifest dependencies, Lua brace balance, `require(...)` resolution, and Wiki data cross-references.
2. Stages a clean production bundle in `dist/archaeology-assistant/` excluding all build scripts and documentation.
3. Compresses the bundle into `dist/archaeology-assistant-v1.0.0.zip` with forward-slash relative paths and verifies that `main.lua` and `plugin.json` sit strictly at the root of the ZIP archive.

### 5. Enable, Permissions & Reload in the RS3 Client
1. In the Beta lobby, click **Import Save** to copy your live character into the Beta world, then enter the game.
2. Open the RS3 Developer Console (`Alt` + `` ` ``) and run:
   - `prf` — Refresh the plugin list
   - `pon prettyui` — Enable the `PrettyUI` dependency
   - `ppr archaeology-assistant` — Unlock the permissions checkbox for `archaeology-assistant` in Dev Mode
3. Open the in-game **Plugin Hub** menu, select **Archaeology Assistant**, and manually tick the **`chatAccess`** permission checkbox (required for Sign of the Porter & Grace of the Elves excavation tracking).
4. Enable or reload the plugin from the Developer Console (`Alt` + `` ` ``):
   - `pon archaeology-assistant` — Enable the plugin
   - `prl archaeology-assistant` — Reload the plugin after running `python manage.py deploy`

> **Note on `requiredPermissions` in Dev Mode:**
> For store-installed plugins, the client prompts players to accept required permissions during installation. For local `dev_plugins`, required permissions start locked in the Plugin Hub UI. Running `ppr archaeology-assistant` in the developer console unlocks the checkbox so you can manually tick `chatAccess` in the in-game Plugin Hub settings.
