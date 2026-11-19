# Archaeology Assistant (RS3 Client Plugin)

**Author:** Brad Evans  
**Required Dependency:** `PrettyUI` (`6398181`)

An official **RuneScape 3 Client API** plugin (Lua 5.4.8) that scans your inventory for damaged and restored Archaeology artefacts, calculates the restoration materials required, tracks your owned materials and artefacts across your **Backpack**, **Workbench Storage**, **Material Storage**, and **Bank**, and shows your live `Owned / Required` (`x/x`) progress, exact material deficits, and 3D world excavation spot indicators.

---

## Plugin Features
- **Dynamic Client `DBTable` Data + Minimal Wiki Extras**:
  - At startup, [`core/db_extractor.lua`](core/db_extractor.lua) dynamically extracts all 69 materials, 250 artefacts, 79 permanent collections (filtering out seasonal event collections), and 102 excavation hotspots directly from RS3's `DBTable` / `DBRow` APIs so new dig sites and collections stay current automatically.
  - Only fields not exposed on `DBRow`s (artefact chronote values in `Artefacts.CHRONOTES` and collection reward/repeatability metadata in `Collections.EXTRAS`) are maintained in `data/*.lua` via `scripts/update_wiki_data.py`.
- **Three Dedicated Views (Tabs) with Sticky Header**:
  - Navigation tabs, search/level filters, and sync status badges (`Collectors`, `Workbench`, `Storage`, `Bank`) remain pinned above the scroll area while scrolling.
  - **Collections Tab (First)**:
    - Lists all 79 RS3 Archaeology collections with required levels, collector NPCs, and required artefacts.
    - **Account Benefits & Relic Powers Highlighted**: Highlights critical unlocks with visual tags and distinct styling under the **Reward** column:
      - **Relic / Monolith Powers** in Cyan (e.g. `Font of Life (+500 Max LP)`, `Pouch Protector`, `Death Ward`, `Inspire Genius`, `Inspire Love`, `Inspire Effort`, `Inspire Awe`, `Nexus Mod`).
      - **T97 Weapon Components** in Gold (e.g. `Inquisitor staff piece`).
      - **Mystery & Blueprint Unlocks** in Amber (e.g. `Howl's Thinking Cap`, `Koschei's needle`).
      - **Repeatable Tetracompass Farming** in Cream (e.g. Green Gobbo Goodies, Red Rum Relics, Zarosian, Guthixian).
    - **Automatic VarPlayer Collector Sync**: Syncs all 13 collectors, completed collections (`_COMPLETE`), and partially submitted artefacts in one pass via `var.VarPlayer.COLLECTION_*` and `config.Achievement.FromID` whenever you carry/equip your Archaeology Journal or walk within 32 tiles of the Archaeology Guild noticeboard. Live hand-ins to collectors in dialogue also update collection progress immediately.
    - **Per-Collector Sync Tracking (`Collectors: X/13`)**: Dedicated toolbar badge on the Collections tab showing live sync status across all 13 collectors, with colour-coded checklist tooltips.
    - **Proportional Collection & Reward Resizing**: Window resize width is shared proportionally between **Collection** and **Reward** so both remain legible.
    - **Progress Column & Artefact Distinction**: Shows live completion progress as `X / Y` (handed in + restored + damaged out of total required). Previously submitted items are displayed in distinct **Cyan** in the collection tooltip alongside exact Bag, Bench, and Bank locations for restored and damaged pieces.
    - **Multi-Collection Tracking ("Collection-Level Pinning")**:
      - Click `Track` on any collection to track it; track multiple collections simultaneously.
      - Automatically sets required artefact targets and scales required restoration materials and deficits in the Materials tab (excluding any artefacts already submitted to collectors).
      - Excavating duplicate damaged artefacts for a tracked collection does not inflate your target repair count beyond what the collection needs.
      - Displays tracked collection tags on artefacts in the Artefacts tab.
    - **Clean Tooltip Inspection**: Hovering any collection shows the collector's exact hand-in location across Gielinor, account benefits, recurring rewards, chronotes, and a concise checklist of every required artefact with its live status (`Handed in to collector`, `Restored (in Bag/Bank)`, `Damaged (in Bag/Bank)`, `Missing`).
    - **Filter & Management**: Toolbar controls include `Col` filter (`Show: All`, `Incomplete`, `Targeted`, `Powers/Relics`, `Tetra Pieces`, `Unsynced`), `Lvl` level filter (applied across Collections, Artefacts, and Materials), `Clear Tracked`, and `Collectors: X/13`, plus independent source toggles (`Backpack`, `Material Storage`, `Bank`, `Workbench Storage`) in the Plugin Hub settings.
    - **Targeted Collections Total Chronotes Bounty**: Displays the combined total Chronote payout across all currently targeted collections directly on the Collections tab header (`Collections (X | +Y)`).
  - **Artefacts Tab (Second)**:
    - Scans damaged and restored artefacts across your **Backpack**, **Workbench Storage**, and **Bank**, including uncollected artefacts targeted by collections.
    - **`Dmg / Rst` Column & Location Tags**: Displays `Damaged / Restored` counts with `(Bag)`, `(Bench)`, `(Bank)`, or `(Multi)` tags (prioritising `(Bag)` when restored copies are in your backpack), with full Bag / Bench / Bank breakdowns in the hover tooltip.
    - **Artefact Ownership & Readiness Status (`X/Y Ready`)**: Displays exact repair readiness (`X/Y Ready`) with colour-coded status text (**Green** when ready, **Orange** when only materials are short, and **Red** when damaged artefacts are short or both artefacts and materials are short), with full material deficits in the hover tooltip.
    - **Uncollected Artefact Display & Recipe Deficits**: When collections are tracked, uncollected artefacts are displayed alongside owned artefacts, and their complete restoration materials are added to the Materials tab deficit calculations.
    - **Proportional Artefact & Location Columns**: Displays the excavation hotspot and dig site for every artefact (e.g. `Venator remains (Kharid-et)`), with **Artefact** and **Location** sharing resize width proportionally.
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
  - Scans nearby active world objects (`LocList`) for **Material Caches** (`Material cache (...)`) and all 102 **Excavation Hotspots** yielding materials or artefacts you currently need.
  - **Shows Needed Artefacts Overhead by Name**: If an excavation hotspot yields an artefact required for your tracked collections or inclusion plan, and you do not already have enough damaged or repaired copies, the artefact appears directly on the overhead badge with its in-game item icon and cyan label displaying the artefact name (e.g. `x1 Venator dagger`).
  - **Visually Unique Styling**: Hotspots yielding needed artefacts feature a distinct, vibrant **Cyan** border and downward pointer chevron so you can identify needed artefact spots across the dig site at a glance.
  - Overhead indicators display each obtainable needed material with its in-game item sprite, live deficit quantity, and percentage likelihood based on the spot's material pool (e.g. `100%` for material caches, `25%` for 4-material hotspots).
  - **Active & Proximity Priority**: Currently excavated hotspots are prioritised on top (`MoveToFront()`), followed by nearest spots (`distSq`), with raised zoom-scaled offsets to keep time sprites clear.
  - **Dynamic Real-Time Dismissal ("until they're gone")**: As you collect materials (via inventory updates or Sign of the Porter cart transfers) or excavate damaged artefacts, required counts decrease in real time; once all needed items from a spot are satisfied, the indicator and highlight vanish automatically.
  - **Zero-Stutter Performance Architecture**: Fast-path stationary caching bypasses world object searches when standing still excavating, slot text/layout is cached during `Event.Draw`, projection calls avoid per-frame closure allocations, and `LocType`/cursor config scoring filters out non-excavation decorative scenery sharing a hotspot name.
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
- [`plugin.json`](plugin.json) — RS3 plugin manifest (declares `prettyui: 6398181` dependency, `chatAccess` permission, and ribbon bar icon)
- [`main.lua`](main.lua) — Plugin entrypoint, event subscriptions, and `PluginShutdown()` persistence hook
- [`tracker.lua`](tracker.lua) — State coordinator for source modes, filters, collection progress, and material/artefact deficit calculations
- **`core/` — Single-Responsibility Domain & Infrastructure Modules**:
  - [`core/utils.lua`](core/utils.lua) — Shared string normalization, HTML/colour tag stripping, number formatting, and table helpers
  - [`core/db.lua`](core/db.lua) — Safe `PersistentDB` wrapper and deterministic map/set/submission serializers
  - [`core/db_extractor.lua`](core/db_extractor.lua) — Runtime `DBTable` / `DBRow` extractor populating materials, artefacts, collections, and hotspots directly from the RS3 client
  - [`core/inventory_scanner.lua`](core/inventory_scanner.lua) — Backpack, Workbench Storage, Bank, and Material Storage scanner with Area Loot and recipe preview isolation
  - [`core/noticeboard_scanner.lua`](core/noticeboard_scanner.lua) — `VarPlayer.COLLECTION_*` and `config.Achievement` collector sync engine (gated on Archaeology Journal or Guild noticeboard proximity)
  - [`core/chat_parser.lua`](core/chat_parser.lua) — Sign of the Porter, Grace of the Elves, collector hand-in, and excavation discovery chat parser
- **`data/` — Slimmed Runtime Shells & Wiki Extras**:
  - [`data/materials.lua`](data/materials.lua) — Runtime shell populated by `DBExtractor.syncAll()`
  - [`data/artefacts.lua`](data/artefacts.lua) — Runtime shell + `Artefacts.CHRONOTES` lookup (45 entries not exposed on `DBRow`s)
  - [`data/hotspots.lua`](data/hotspots.lua) — Runtime shell populated by `DBExtractor.syncAll()`
  - [`data/collections.lua`](data/collections.lua) — Runtime shell + `Collections.EXTRAS` metadata (79 entries for rewards/repeatability)
- **`ui/` — Modular PrettyUI Components**:
  - [`ui/theme.lua`](ui/theme.lua) — Shared colour palette, layout constants, font resolution, and text wrapping height measurement
  - [`ui/tooltip.lua`](ui/tooltip.lua) — Floating tooltip component and tooltip content builders for collections, artefacts, materials, and sync badges
  - [`ui/widgets.lua`](ui/widgets.lua) — Reusable UI component factories (toolbar buttons, sync badges, collector sync pill, table rows, resize handles)
  - [`ui/window.lua`](ui/window.lua) — Main `PrettyUI` movable, resizable, scrollable 3-tab window and Ribbon Bar hub
  - [`ui/overlay.lua`](ui/overlay.lua) — In-game 3D world spot highlighter and overhead deficit indicator badges

### Cross-Platform Python Toolchain (Excluded from Plugin Bundle)
All build, Wiki data scraping, validation, deployment, and Mod.io packaging tasks are written in standard-library **Python 3.10+** (`manage.py` and `scripts/*.py`) so they run identically on **Windows, macOS, and Linux** without external pip dependencies:
- [`manage.py`](manage.py) — Unified cross-platform CLI entrypoint (`update-data`, `build`, `deploy`, `package`, `launch-beta`)
- [`scripts/update_wiki_data.py`](scripts/update_wiki_data.py) — Scrapes supplemental Wiki metadata not exposed on game `DBRow`s (artefact chronotes and collection rewards/benefits) from `https://runescape.wiki` and regenerates the slim `data/*.lua` files
- [`scripts/build_plugin.py`](scripts/build_plugin.py) — Validates `plugin.json`, Lua syntax/brace balance, local `require(...)` graph, and data integrity, then stages the runtime bundle in `dist/archaeology-assistant/` (and optionally deploys to the local RS3 plugin directory)
- [`scripts/package_submission.py`](scripts/package_submission.py) — Runs the full build validation and packages `dist/archaeology-assistant-v<version>.zip` with root-level `main.lua` and `plugin.json` for Mod.io
- [`scripts/launch_beta.py`](scripts/launch_beta.py) — Builds, deploys, and opens the `rs-launch://` URI via the OS URL handler
- [`deploy.cmd`](deploy.cmd), [`package.cmd`](package.cmd), [`launch-beta.cmd`](launch-beta.cmd) — Convenience Windows batch wrappers that invoke `manage.py`

---

## Developer Workflow: Updating Data, Building & Packaging

### Prerequisites
- **Python 3.10+** (no third-party packages required; uses only Python's standard library).

### 1. Refresh Supplemental Wiki Metadata (Chronotes & Collection Rewards)
Core materials, artefacts, collections, collector locations, and hotspots are loaded dynamically from the RuneScape client's `DBTable`s at runtime. To refresh the supplemental metadata not exposed on `DBRow`s (artefact chronote values and collection rewards/benefits), run:
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
3. Compresses the bundle into `dist/archaeology-assistant-v1.0.3.zip` with forward-slash relative paths and verifies that `main.lua` and `plugin.json` sit strictly at the root of the ZIP archive.

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
