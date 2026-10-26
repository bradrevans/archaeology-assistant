# Archaeology Assistant — Planned Features & Community Roadmap

This document compiles community feature requests and suggestions collected from the [Reddit Launch Post](https://www.reddit.com/r/runescape/comments/1xfdq26/archaeology_assistant_plugin_development/) and player feedback, organized by priority and implementation scope.

---

## 📋 Near-Term Features (Tier 1: Low-to-Medium Cost)

Planned for upcoming updates:

### 1. Archaeology Level Filtering & Highlighting
* **Description**: Option to filter collections and damaged artefacts to only those at or below the player's current Archaeology level.
* **Value**: Prevents novice and mid-level players from having their lists cluttered by high-level 100+ collections and artefacts they cannot yet excavate or restore.
* **Implementation Note**: Read player Archaeology level from the skills interface/engine stats and apply a `col.level <= playerLevel` filter option.

### 2. In-Game Search Bar (Collections & Artefacts)
* **Description**: A search input box at the top of the Collections, Artefacts, and Materials tables allowing quick typing (e.g. typing "gobbo", "zaros", "cadmium", or "falador").
* **Value**: Enables instantaneous lookup among 79 collections and hundreds of artefacts without manual scrolling.
* **Implementation Note**: Utilize PrettyUI text input hooks or character filter buffer to match against item and collection names in real time.

### 3. Grand Exchange / Buy Cost Material Calculator
* **Description**: Estimates the total GP cost to purchase all missing materials from the Grand Exchange.
* **Value**: Players seeking fast XP or quick collection completions can immediately know how much gold is needed to buy out their deficit shopping list.
* **Implementation Note**: Cache Grand Exchange guide prices or provide estimated price multipliers alongside total material quantities.

### 4. Collection Repeatable Completion Counter
* **Description**: Display a counter tracking how many times each repeatable collection has been handed in (e.g. `Completed 12x`).
* **Value**: Crucial for players tracking progress towards high-tier rewards, chronote farming goals, or bulk Tetracompass piece accumulation.

### 5. Artefact Sorting Options
* **Description**: Allow sorting the Artefacts table by Level (Asc/Desc), Restoration XP, Chronotes Yield, or Name.
* **Value**: Helps players prioritize the most efficient artefacts for training or chronote farming.

---

## 🔮 Advanced / Long-Term Features (Tier 2: High-Value Systems)

Planned for future major updates:

### 1. Time Sprite 3D Overhead & Focus Helper
* **Description**: High-visibility 3D reticle or arrow pointing to the active Time Sprite as it jumps between excavation hotspots, with an indicator showing the player's current sprite focus percentage.
* **Value**: Significantly eases semi-AFK training by highlighting when and where the sprite moves without squinting at particle effects.
* **Implementation Note**: Hook into active NPC entities with matching Time Sprite IDs or local animations.

### 2. Dig Site Mystery Step-by-Step Guidance
* **Description**: Interactive quest-style tracker for all dig site mysteries (e.g. Kharid-et shadows, Infernal Source portals, Stormguard boots).
* **Value**: Removes the need to alt-tab to the Wiki for puzzle step solutions, required pages, and unlock requirements.
* **Implementation Note**: Structured data dictionary of all 24+ mysteries with prerequisite and stage completion checks.

### 3. Research Expedition Timers & Team Overview
* **Description**: Track active research missions sent from the Archaeology Guild, showing remaining time, team composition, and expected XP/chronote yields.
* **Value**: Prevents wasted downtime when expeditions finish while players are training elsewhere.
* **Implementation Note**: Monitor mission dispatch timestamps and interface completion hooks.

### 4. Bank Preset & 1-Click Repair Withdraw Assistant
* **Description**: Displays exact withdraw quantities needed to restore current damaged artefacts from the bank, with visual markers over corresponding bank slots.
* **Value**: Streamlines the process of prepping inventory for mass restoration sessions at the workbench.
