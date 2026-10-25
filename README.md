# Archaeology Assistant (RS3 Client Plugin)

**Author:** Brad Evans (`bradrevans@gmail.com`)  
**Version:** `0.2.0`  
**Required Dependency:** `PrettyUI` (`6398181`)

An official **RuneScape 3 Client API** plugin (Lua 5.4.8) that scans your inventory for damaged Archaeology artefacts, calculates the restoration materials required, tracks your owned materials across your **Backpack**, **Material Storage**, and **Bank**, and shows your live `Owned / Required` (`x/x`) progress and exact material deficits.

---

## Features (v0.2.0)
- **Complete RS3 Artefact, Material & Collection Database**: Includes all 231 damaged artefacts (levels 1–120), all 47 Archaeology materials + 22 secondary items, and all 79 collector Collections.
- **Three Dedicated Views (Tabs)**:
  - **Collections Tab (First)**:
    - Lists all 79 RS3 Archaeology collections with required levels, collector NPCs, and required artefacts.
    - **Account Benefits & Relic Powers Obvious**: Highlights critical unlocks with visual tags and distinct styling under the **Reward** column:
      - **Relic / Monolith Powers** in Cyan (e.g. `Font of Life (+500 Max LP)`, `Pouch Protector`, `Death Ward`, `Inspire Genius`, `Inspire Love`, `Inspire Effort`, `Inspire Awe`, `Nexus Mod`).
      - **T97 Weapon Components** in Gold (e.g. `Inquisitor staff piece`).
      - **Mystery & Blueprint Unlocks** in Amber (e.g. `Howl's Thinking Cap`, `Koschei's needle`).
      - **Repeatable Tetracompass Farming** in Cream (e.g. Green Gobbo Goodies, Red Rum Relics, Zarosian, Guthixian).
    - **Automatic Achievement Syncing**: Collection completion (`Done` in green vs `-` in muted) is read-only and automatically queried from in-game client achievements on startup and in real time without requiring opening any noticeboard. Permanent completion progress is preserved even when clearing temporary inventory caches.
    - **Dynamic Collection Resizing**: 100% of window resize width expansion is allocated to the **Collection** column so collection names are never truncated.
    - **Turn-In, Submitted & Damaged vs Restored Distinction**: Live scan of artefacts across your Backpack and Bank distinguishes between items already submitted to collectors, restored artefacts ready for turn-in, and damaged artefacts waiting to be restored (e.g. `Ready!`, `2/3 (1 Dmg)`, or `0/3 (2 Dmg)`). Previously submitted items are taken into account so they never block completion progress or generate unnecessary restoration requirements.
    - **Multi-Collection Tracking ("Collection-Level Pinning")**:
      - Click `Track` on any collection to track it; track multiple collections simultaneously.
      - Automatically sets required artefact targets and scales required restoration materials and deficits in the Materials tab (excluding any artefacts already submitted to collectors).
      - Displays tracked collection tags on artefacts in the Artefacts tab.
    - **Clean Multiline Tooltip Inspection**: Hovering any collection shows collector location, account benefits, recurring rewards, chronotes, and a complete syntax-highlighted checklist of every required artefact with its live status (`Submitted to collector`, `Restored`, `Damaged to restore`, `Missing`) with zero unprintable newline glyphs.
    - **Filter & Management**: Toolbar filter button (`Show: All`, `Incomplete`, `Targeted`, `Powers/Relics`) and `Clear Tracked` button.
  - **Artefacts Tab (Second)**:
    - Scans damaged artefacts across your **Backpack** and **Bank**, including uncollected artefacts targeted by collections.
    - **Artefact Ownership Required for Ready Status**: An artefact requires actual damaged artefact ownership to be marked "Ready". If an artefact is required for a tracked collection but not yet excavated (`Owned: 0`), its status clearly displays `Need Art` (when materials are satisfied) or `Short (Art+Mats)` (when materials are also missing).
    - **Wider Status Column (110px)**: Completely expanded to comfortably fit all detailed statuses (`Short (Art+Mats)`, `Need Art`, `Ready (X/Y)`, `0 (Can Repair)`, `Short (N mats)`) without clipping.
    - **Uncollected Artefact Display & Recipe Deficits**: When collections are tracked, uncollected artefacts are displayed alongside owned artefacts, and their complete restoration materials are added to the Materials tab deficit calculations.
    - **Location Column**: Displays the excavation hotspot and dig site for every artefact (e.g. `Venator remains (Kharid-et)`), with dynamic width expansion on resize.
    - **Artefact Source Filtering**: Dedicated toolbar filter button (`Show: All`, `Show: Tracked`, `Show: Owned`) to instantly isolate artefacts needed for your tracked collections.
    - Displays in-game item icons alongside artefact names.
    - Hovering any row displays a rich floating tooltip with an enlarged (32x32) in-game item sprite, location, restoration XP, Chronotes, targeted collection sources, and the complete materials recipe with live `owned / required` quantities scaled to your target count.
    - Direct **Include** quantity controls (**`+` / `-`** steppers, with `0` cleanly excluding an artefact from material calculations).
    - **Flexible Inclusion Modes (`Dupes` button)**: Cycle between **Dupes: All**, **Dupes: 1x**, and **Include: 0** (sets all includes to 0 across the board for selective single-artefact repairs). Switching back to `All` or `1x` cleanly re-includes previously excluded artefacts.
    - Displays artefact level, owned quantities (`Bag`, `Bank`, or `0` for uncollected collection targets), and live repair status (`Ready`, `X / Y Ready`, `Need Art`, `Short (Art+Mats)`, or `Excluded`).
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
  - **Shows Needed Artefacts Overhead**: If an excavation hotspot yields an artefact required for your tracked collections or inclusion plan, and you do not already have enough damaged or repaired copies, the artefact appears directly on the overhead badge with its in-game item icon and cyan `x1 (Art)` label.
  - **Visually Unique Styling**: Hotspots yielding needed artefacts feature a distinct, vibrant **Cyan** border and downward pointer chevron so you can identify needed artefact spots across the dig site at a glance.
  - Overhead indicators display each obtainable needed material with its in-game item sprite, live deficit quantity, and percentage likelihood based on the spot's material pool (e.g. `100%` for material caches, `25%` for 4-material hotspots).
  - **Dynamic Real-Time Dismissal ("until they're gone")**: As you collect materials (via inventory updates or Sign of the Porter cart transfers) or excavate damaged artefacts, required counts decrease in real time; once all needed items from a spot are satisfied, the indicator and highlight vanish automatically.
  - Fully click-through: does not block interaction with the world or the excavation spot.
- **Native `PrettyUI` Movable, Resizable & Scrollable Window**:
  - Uses `prettyui.Window` (`6398181`) with smooth scrolling, edge/corner resizing, and automatic geometry and visibility persistence in `PersistentDB`.
  - Integrates with the **RS3 Ribbon Bar** (`hasRibbonIcon: true`) so you can show/hide the window anytime from the plugin hub.
  - Clean responsive reflow: expanding the window allocates 100% of extra width to the `Location` column (Materials & Artefacts) and `Collection` column (Collections).
  - **Full Mouse Wheel Table Scrolling**: Scrolling anywhere over table rows, buttons, steppers, headers, summary card, or the scrollbar scrolls smoothly without getting blocked, and active tooltips dismiss immediately upon scrolling.
- **Cache Management (Ribbon Bar Hub)**:
  - Accessible via the Ribbon Bar hub panel.
  - **Clear All Cache & Saved Data**: Completely wipes cached Material Storage and Bank contents, tracked targets, and custom quantity overrides while preserving permanent account achievement completions.
- **Sync Status Badges with In-Game Icons & Rich Tooltips**:
  - Compact icon badges in the toolbar for **Material Storage** (`Stor`, Archaeology Journal icon) and **Bank** (`Bank`, Coins pile icon) visible across all tabs.
  - Inspecting damaged artefacts or previewing restoration recipes never corrupts Material Storage or mutates the storage badge icon.
  - Hovering displays an enlarged (32x32) item icon and sync instructions (e.g. opening a workbench, checking Material storage information in your Archaeology journal, or opening your Bank).
  - Status dot indicator and borders:
    - **Synced (Green)**: Verified live in the current game session.
    - **Cached (Amber)**: Loaded from previous session cache (resync recommended in case items changed on another device).
    - **Not Synced (Red)**: Container not yet opened / no data.
    - **Ignored (Grey)**: Container excluded by the current `Src` filter mode.
- **Multi-Source Material Tracking (`Src` button)**:
  - Cycle container counting: **Src: All** *(default: Bag + Storage + Bank)*, **Src: Bag+Stor**, **Src: Storage**, **Src: Bag Only**, and **Src: Bag+Bank**.
- **Flexible Artefact Inclusion (`Dupes` button)**:
  - Cycle inclusion modes: **Dupes: All**, **Dupes: 1x**, and **Include: 0** (clears all includes to 0 for selective repair). Switching back to `All` or `1x` re-includes excluded artefacts.
  - Toggle default inclusion between **Dupes: All** and **Dupes: 1x** (or shows **Dupes: Custom** when individual `+`/`-` overrides are active).
- **Porter & Cart Live Tracking**:
  - Automatically retains gathered material progress when depositing via **Material Carts**, Bank Deposit Boxes, or bank chests without requiring a manual Material Storage resync.
  - Automatically credits Sign of the Porter / Grace of the Elves transfers to Material Storage in real time via client chat event handling with required `chatAccess` permissions.
  - Correctly distinguishes material deposits from dropping items (MiniMenu `Drop` action decreases owned counts naturally) and artefact restoration (where required materials are consumed).
  - Area Loot, dialogue containers, and inspection windows are strictly isolated and never overwrite storage cache or reset tracker state.
- **Clean Empty States**:
  - Hides empty tables and reflows window scroll height cleanly when no damaged artefacts are carried or all required materials are ready.

---

## Project Structure

### Runtime Plugin Files (Bundled into `dist/archaeology-assistant`)
- [`plugin.json`](file:///c:/Users/bradr/code/archaeology-assistant/plugin.json) — RS3 plugin manifest (declares `prettyui: 6398181` dependency and ribbon bar icon)
- [`main.lua`](file:///c:/Users/bradr/code/archaeology-assistant/main.lua) — Plugin entrypoint, event subscriptions, and `PluginShutdown()` persistence hook
- [`tracker.lua`](file:///c:/Users/bradr/code/archaeology-assistant/tracker.lua) — Inventory scanner, material deficit calculator, sync prompt analyzer, and pin/filter state manager
- [`ui/window.lua`](file:///c:/Users/bradr/code/archaeology-assistant/ui/window.lua) — In-game `PrettyUI` movable/resizable/scrollable window, sync prompt banner, responsive material table, and Ribbon Bar hub
- [`ui/overlay.lua`](file:///c:/Users/bradr/code/archaeology-assistant/ui/overlay.lua) — In-game 3D world spot highlighter, ground target reticle, and overhead deficit indicator badges
- [`data/materials.lua`](file:///c:/Users/bradr/code/archaeology-assistant/data/materials.lua) — Auto-generated Archaeology material metadata and cache locations
- [`data/artefacts.lua`](file:///c:/Users/bradr/code/archaeology-assistant/data/artefacts.lua) — Auto-generated damaged artefact restoration recipes
- [`data/hotspots.lua`](file:///c:/Users/bradr/code/archaeology-assistant/data/hotspots.lua) — Auto-generated database mapping all 103 RS3 Excavation Hotspots to their yielded materials

### Build & Data Generation Scripts (Excluded from Plugin Bundle)
- [`launch-beta.cmd`](file:///c:/Users/bradr/code/archaeology-assistant/launch-beta.cmd) / [`scripts/Launch-Beta.ps1`](file:///c:/Users/bradr/code/archaeology-assistant/scripts/Launch-Beta.ps1) — One-step command (or double-clickable batch file) that builds, deploys to `C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\archaeology-assistant`, syncs the `PrettyUI` (`6398181`) dependency, and launches the RS3 Plugin Developer Beta client via the Jagex Launcher.
- [`deploy.cmd`](file:///c:/Users/bradr/code/archaeology-assistant/deploy.cmd) — Quick command (or double-clickable batch file) to rebuild and deploy updated files while the Beta client is already running.
- [`scripts/Update-WikiData.ps1`](file:///c:/Users/bradr/code/archaeology-assistant/scripts/Update-WikiData.ps1) — Replayable script that fetches live Archaeology materials, artefact tables, and excavation hotspots from the official RuneScape Wiki, validates recipe integrity, and regenerates `data/materials.lua`, `data/artefacts.lua`, and `data/hotspots.lua`.
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

### 3. Enable, Permissions & Reload in the RS3 Beta Client
1. In the Beta lobby, click **Import Save** to copy your live character into the Beta world, then enter the game.
2. Open the RS3 Developer Console (`Alt` + `` ` ``) and run:
   - `prf` — Refresh the plugin list
   - `ppe archaeology-assistant chatAccess` — Grant the required `chatAccess` permission (required for Sign of the Porter & Grace of the Elves excavation tracking)
   - `pon prettyui` — Enable the `PrettyUI` dependency (if not already enabled)
   - `pon archaeology-assistant` — Enable the plugin
   - `prl archaeology-assistant` — Reload the plugin after running `.\deploy.cmd`

> **Note on `requiredPermissions` in Dev Mode:**
> For store-installed plugins, the client prompts players to accept required permissions during installation. Because `dev_plugins` are loaded directly from disk without going through the store install prompt, the client lists required permissions as non-toggleable in the UI. Running `ppe archaeology-assistant chatAccess` (or `ppr archaeology-assistant`) in the developer console grants the permission immediately.

