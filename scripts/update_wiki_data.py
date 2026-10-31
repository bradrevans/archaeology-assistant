#!/usr/bin/env python3
"""
Cross-platform RuneScape Wiki scraper and Lua data generator for Archaeology Assistant.

Dynamically scrapes and generates:
  - data/materials.lua   (Archaeology materials, tutorial materials, and secondary items)
  - data/artefacts.lua   (All damaged/restored artefacts, levels, XP, chronotes, recipes, item IDs)
  - data/hotspots.lua    (Excavation hotspots -> level & yielded materials)
  - data/collections.lua (All collections, collector hand-in locations, required artefacts,
                          and dynamically classified relic/weapon/mystery/tetra rewards)

Usage:
  python scripts/update_wiki_data.py [--dry-run]
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

USER_AGENT = "ArchaeologyAssistant-WikiUpdater/2.0 (RS3 Lua Plugin; https://runescape.wiki)"
WIKI_BASE = "https://runescape.wiki"
API_ENDPOINT = f"{WIKI_BASE}/api.php"


# ============================================================================
# HTTP & MediaWiki API Helpers
# ============================================================================

def fetch_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", errors="replace")


def fetch_json(params: dict[str, str]) -> dict[str, Any]:
    query = urllib.parse.urlencode(params)
    raw = fetch_text(f"{API_ENDPOINT}?{query}")
    return json.loads(raw)


def fetch_wiki_raw(page_title: str) -> str:
    encoded = urllib.parse.quote(page_title.replace(" ", "_"), safe="()_:-'")
    return fetch_text(f"{WIKI_BASE}/w/{encoded}?action=raw").replace("\r\n", "\n")


def fetch_wiki_html(page_title: str) -> str:
    encoded = urllib.parse.quote(page_title.replace(" ", "_"), safe="()_:-'")
    return fetch_text(f"{WIKI_BASE}/w/{encoded}").replace("\r\n", "\n")


def fetch_wiki_parsed_html(page_title: str) -> str:
    data = fetch_json({
        "action": "parse",
        "page": page_title,
        "prop": "text",
        "format": "json",
        "redirects": "1",
    })
    return data.get("parse", {}).get("text", {}).get("*", "")


def query_pages_wikitext(titles: list[str]) -> dict[str, str]:
    """Queries MediaWiki revisions API in batches of up to 40 titles."""
    results: dict[str, str] = {}
    unique_titles = list(dict.fromkeys(t.strip() for t in titles if t and t.strip()))
    batch_size = 40

    for i in range(0, len(unique_titles), batch_size):
        batch = unique_titles[i : i + batch_size]
        data = fetch_json({
            "action": "query",
            "prop": "revisions",
            "rvprop": "content",
            "rvslots": "main",
            "redirects": "1",
            "format": "json",
            "titles": "|".join(batch),
        })
        query_block = data.get("query", {})
        pages = query_block.get("pages", {})
        for page in pages.values():
            title = page.get("title", "")
            revs = page.get("revisions", [])
            if not revs:
                continue
            slot = revs[0].get("slots", {}).get("main", {})
            wikitext = slot.get("*", "") or revs[0].get("*", "")
            if wikitext and title:
                results[title] = wikitext

        for r in query_block.get("redirects", []):
            if r.get("to") in results and r.get("from"):
                results[r["from"]] = results[r["to"]]

        for n in query_block.get("normalized", []):
            if n.get("to") in results and n.get("from"):
                results[n["from"]] = results[n["to"]]

    return results


# ============================================================================
# String & Wikitext Cleaning Helpers
# ============================================================================

def strip_tags_and_decode(value: str) -> str:
    if not value:
        return ""
    s = re.sub(r"<[^>]+>", "", value)
    s = html.unescape(s)
    s = s.replace("\u00a0", " ").replace("&#160;", " ").replace("&nbsp;", " ")
    return re.sub(r"\s+", " ", s).strip()


def clean_wiki_text(value: str) -> str:
    if not value:
        return ""
    s = html.unescape(value)
    s = s.replace("\u00a0", " ").replace("&#160;", " ").replace("&nbsp;", " ")
    s = re.sub(r"<!--.*?-->", "", s, flags=re.DOTALL)
    s = re.sub(r"<ref[^>]*>.*?</ref>", "", s, flags=re.DOTALL | re.IGNORECASE)
    s = re.sub(r"<ref[^/>]*/\s*>", "", s, flags=re.IGNORECASE)
    s = re.sub(r"<br\s*/?>", ", ", s, flags=re.IGNORECASE)
    s = re.sub(r"<[^>]+>", "", s)
    s = re.sub(r"\[\[(?:File|Image):[^\]]+\]\]", "", s, flags=re.IGNORECASE)
    s = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", s)
    s = re.sub(r"\[\[([^\]]+)\]\]", r"\1", s)
    s = re.sub(r"\{\{(?:Coins|Chronotes)\|([0-9,]+)\}\}", r"\1", s, flags=re.IGNORECASE)
    s = re.sub(r"\{\{(?:plink|plinkt|illi|inline icon)\|([^}|]+)(?:\|[^}]*)?\}\}", r"\1", s, flags=re.IGNORECASE)
    s = re.sub(r"\{\{[^{}]*\}\}", "", s)
    s = s.replace("'''", "").replace("''", "")
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"^[,;\s]+|[,;\s]+$", "", s)
    return s


def escape_lua(value: str) -> str:
    if not value:
        return ""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def extract_infobox_param(wikitext: str, param_names: list[str]) -> str:
    for param in param_names:
        pattern = rf"\|\s*{re.escape(param)}\s*=\s*([^\n|}}]+)"
        m = re.search(pattern, wikitext, flags=re.IGNORECASE)
        if m:
            cleaned = clean_wiki_text(m.group(1))
            if cleaned:
                return cleaned
    return ""


def extract_item_id_from_wikitext(wikitext: str) -> int | None:
    if not wikitext:
        return None
    m = re.search(r"id\d*\s*=\s*(\d+)", wikitext, flags=re.IGNORECASE)
    return int(m.group(1)) if m else None


# ============================================================================
# 1. Scrape Archaeology Materials (including Tutorial Materials)
# ============================================================================

def scrape_materials() -> tuple[list[dict[str, Any]], dict[str, str]]:
    print("[1/5] Fetching Materials_(Archaeology) from RuneScape Wiki...")
    raw = fetch_wiki_raw("Materials_(Archaeology)")

    materials: list[dict[str, Any]] = []
    arch_mat_names: dict[str, str] = {}

    for row in re.split(r"(?m)^\|-", raw):
        lines = [ln.strip() for ln in row.splitlines() if ln.strip().startswith("|")]
        if len(lines) < 2:
            continue

        m_lv = re.match(r"^\|\s*(\d+)\s*$", lines[0])
        m_nm = re.search(r"\{\{plinkt?\|([^}|]+)", lines[1], flags=re.IGNORECASE)
        if not (m_lv and m_nm):
            continue

        lvl = int(m_lv.group(1))
        name = html.unescape(m_nm.group(1)).strip()
        culture = "Tutorial"
        caches: list[str] = []

        if len(lines) >= 5:
            culture = lines[3].lstrip("|").strip()
            raw_caches = lines[4].lstrip("|").strip()
            for cm in re.finditer(r"\[\[(?:[^|\]]+\|)?([^\]]+)\]\]", raw_caches):
                val = html.unescape(cm.group(1)).strip()
                if val and val not in caches:
                    caches.append(val)

        materials.append({
            "id": None,
            "name": name,
            "level": lvl,
            "culture": culture,
            "isArchMaterial": True,
            "caches": caches,
        })
        arch_mat_names[name.lower()] = name

    if len(materials) < 40:
        raise RuntimeError(f"Expected at least 40 Archaeology materials, parsed {len(materials)}")

    print(f"      -> Parsed {len(materials)} Archaeology materials.")
    return materials, arch_mat_names


# ============================================================================
# 2. Scrape Artefacts & Secondary Restoration Items
# ============================================================================

def scrape_artefacts(arch_mat_names: dict[str, str]) -> tuple[list[dict[str, Any]], list[str]]:
    print("[2/5] Fetching Artefacts from RuneScape Wiki...")
    art_html = fetch_wiki_html("Artefacts")
    tr_matches = list(
        re.finditer(
            r'(?s)<tr data-rowid="([^"]+)">(.*?)</tr>\s*(?=<tr data-rowid="|</tbody></table>\s*<div)',
            art_html,
        )
    )
    if len(tr_matches) < 200:
        raise RuntimeError(f"Expected at least 200 artefacts, found {len(tr_matches)}")

    artefacts: list[dict[str, Any]] = []
    secondary_set: set[str] = set()

    for tm in tr_matches:
        name = html.unescape(tm.group(1)).strip()
        tr_body = tm.group(2)

        m_lvl = re.search(r'<td data-sort-value="(\d+)">', tr_body)
        level = int(m_lvl.group(1)) if m_lvl else 1

        damaged_name = f"{name} (damaged)"
        recipe: list[dict[str, Any]] = []

        m_table = re.search(r'(?s)<table class="products-materials"[^>]*>(.*?)</table>', tr_body)
        if m_table:
            for sr in re.finditer(r'(?s)<tr class="nohighlight">(.*?)</tr>', m_table.group(1)):
                sr_text = sr.group(1)
                m_qty = re.search(r">\s*([\d,]+)\s*(?:\u00d7|&#215;|&times;|[^\s\d<]+)\s*<", sr_text)
                links = list(re.finditer(r'<a [^>]*title="([^"]+)"[^>]*>([^<]+)</a>', sr_text))
                if m_qty and links:
                    qty = int(m_qty.group(1).replace(",", ""))
                    last_link = links[-1]
                    item_title = html.unescape(last_link.group(1)).strip()
                    item_text = html.unescape(last_link.group(2)).strip()

                    if (
                        "(damaged)" in item_text.lower()
                        or "(damaged)" in item_title.lower()
                        or item_text.lower().endswith("(unpowered)")
                    ):
                        damaged_name = item_text
                    else:
                        recipe.append({"name": item_text, "count": qty})
                        if item_text.lower() not in arch_mat_names:
                            secondary_set.add(item_text)

        if not recipe:
            raise RuntimeError(f"Artefact '{name}' had 0 parsed restoration materials")

        m_chrono = re.search(r"chronotes-100[^>]*>([\d,]+)<", tr_body)
        chronotes = int(m_chrono.group(1).replace(",", "")) if m_chrono else 0

        xp: float | int = 0
        parts = tr_body.split("</table></td>", 1)
        if len(parts) == 2:
            td_matches = list(re.finditer(r'<td(?:\s+data-sort-value="([^"]+)")?[^>]*>', parts[1]))
            if len(td_matches) >= 2 and td_matches[1].group(1):
                try:
                    xp_val = float(td_matches[1].group(1))
                    xp = int(xp_val) if xp_val.is_integer() else xp_val
                except ValueError:
                    xp = 0

        artefacts.append({
            "id": None,
            "name": name,
            "damagedName": damaged_name,
            "level": level,
            "location": "",
            "xp": xp,
            "chronotes": chronotes,
            "materials": recipe,
        })

    secondary_items = sorted(secondary_set)
    print(f"      -> Parsed {len(artefacts)} artefacts and {len(secondary_items)} secondary items.")
    return artefacts, secondary_items


# ============================================================================
# 3. Scrape Excavation Hotspots & Dynamically Resolve Special Artefact Sources
# ============================================================================

def resolve_missing_artefact_sources(missing_art_names: list[str]) -> dict[str, str]:
    """
    Dynamically resolves hotspot/location strings for artefacts not in the main
    Excavation_hotspots table by querying their RuneScape Wiki pages.
    """
    resolved: dict[str, str] = {}
    if not missing_art_names:
        return resolved

    pages = query_pages_wikitext(missing_art_names + [f"{n} (damaged)" for n in missing_art_names])
    for name in missing_art_names:
        wt = pages.get(f"{name} (damaged)", "") or pages.get(name, "")
        if not wt:
            resolved[name] = "Archaeology"
            continue

        # Check if excavated from a specific hotspot linked in the article
        hs_match = re.search(
            r"excavated from (?:the )?\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]",
            wt,
            flags=re.IGNORECASE,
        )
        if hs_match:
            spot = clean_wiki_text(hs_match.group(1))
            if "Centurion remains" in spot or "Centurion remains" in wt:
                resolved[name] = "Centurion remains (Guild)"
            else:
                site_m = re.search(r"\[\[([A-Za-z' -]+?) Dig Site", wt, flags=re.IGNORECASE)
                site = clean_wiki_text(site_m.group(1)) if site_m else ""
                resolved[name] = f"{spot} ({site})" if site else spot
            continue

        if "Centurion remains" in wt:
            resolved[name] = "Centurion remains (Guild)"
        elif "Big High War God shrine" in wt:
            resolved[name] = "Big High War God shrine (Warforge)"
        elif re.search(r"Stormguard Citadel", wt, re.IGNORECASE):
            resolved[name] = "Stormguard Citadel"
        elif re.search(r"Tetracompass", name, re.IGNORECASE):
            resolved[name] = "Tetracompass rewards"
        else:
            loc_param = extract_infobox_param(wt, ["location", "digsite", "site"])
            resolved[name] = loc_param if loc_param else "Archaeology"

    return resolved


def scrape_excavation_hotspots(
    artefacts: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    print("[3/5] Fetching Excavation_hotspots from RuneScape Wiki...")
    h_html = fetch_wiki_parsed_html("Excavation_hotspots")

    hotspots_map: dict[str, dict[str, Any]] = {}
    art_to_loc: dict[str, str] = {}

    for h_row in re.split(r"<tr>", h_html):
        m_level = re.search(r'data-level="(\d+)"', h_row)
        m_name = re.search(r'<td><a[^>]*title="([^"]+)"[^>]*>([^<]+)</a></td>', h_row)
        if not (m_level and m_name):
            continue

        level = int(m_level.group(1))
        h_name = html.unescape(m_name.group(2).strip())

        mats: list[str] = []
        td_matches = list(re.finditer(r"(?s)<td[^>]*>(.*?)</td>", h_row))
        if len(td_matches) >= 8:
            site = strip_tags_and_decode(td_matches[3].group(1))
            digsite = strip_tags_and_decode(td_matches[4].group(1))

            if digsite and digsite != "N/A":
                ds_clean = re.sub(r" Dig Site$", "", digsite)
                loc_str = f"{h_name} ({ds_clean})"
            elif site and site != "N/A":
                s_clean = re.sub(r" excavation site$", "", site)
                s_clean = re.sub(r" - Exterior$", "", s_clean)
                loc_str = f"{h_name} ({s_clean})"
            else:
                loc_str = h_name

            art_cell = td_matches[6].group(1)
            for am in re.finditer(r'title="([^"]+)"', art_cell):
                a_name = html.unescape(am.group(1).strip())
                if not re.search(r"Category:|File:|Special:", a_name):
                    base = re.sub(r" \(damaged\)$", "", a_name)
                    if base not in art_to_loc:
                        art_to_loc[base] = loc_str

            mats_cell = td_matches[7].group(1)
            for mm in re.finditer(r'title="([^"]+)"', mats_cell):
                mat_name = html.unescape(mm.group(1).strip())
                if not re.search(r"Category:|File:|Special:", mat_name) and mat_name not in mats:
                    mats.append(mat_name)

        if h_name not in hotspots_map:
            hotspots_map[h_name] = {"level": level, "materials": mats}
        else:
            for mat in mats:
                if mat not in hotspots_map[h_name]["materials"]:
                    hotspots_map[h_name]["materials"].append(mat)

    missing_arts = [a["name"] for a in artefacts if a["name"] not in art_to_loc]
    dynamic_fallbacks = resolve_missing_artefact_sources(missing_arts)

    for a in artefacts:
        a["location"] = art_to_loc.get(a["name"]) or dynamic_fallbacks.get(a["name"], "Archaeology")

    print(
        f"      -> Parsed {len(hotspots_map)} excavation hotspots and mapped "
        f"locations for all {len(artefacts)} artefacts."
    )
    return hotspots_map


# ============================================================================
# 4. Resolve In-Game Item IDs for Materials, Secondaries & Artefacts
# ============================================================================

def resolve_all_item_ids(
    materials: list[dict[str, Any]],
    secondary_items: list[str],
    artefacts: list[dict[str, Any]],
) -> None:
    print("[4/5] Resolving in-game item IDs from RuneScape Wiki MediaWiki API...")
    query_titles: list[str] = []
    for m in materials:
        query_titles.append(m["name"])
    for sec in secondary_items:
        query_titles.append(sec)
    for a in artefacts:
        query_titles.append(a["damagedName"])
        query_titles.append(a["name"])
    query_titles.extend(["Tetracompass (unpowered)", "Spear of Annihilation with shaft + spokes"])

    wikitext_map = query_pages_wikitext(query_titles)
    item_id_map: dict[str, int] = {}
    for title, wt in wikitext_map.items():
        found_id = extract_item_id_from_wikitext(wt)
        if found_id is not None:
            item_id_map[title] = found_id

    if "Tetracompass (unpowered)" in item_id_map:
        item_id_map["Tetracompass (unpowered) (damaged)"] = item_id_map["Tetracompass (unpowered)"]
    if "Spear of Annihilation with shaft + spokes" in item_id_map:
        item_id_map["Spear of Annihilation (damaged)"] = item_id_map["Spear of Annihilation with shaft + spokes"]

    for m in materials:
        m["id"] = item_id_map.get(m["name"])

    for sec in secondary_items:
        materials.append({
            "id": item_id_map.get(sec),
            "name": sec,
            "level": 1,
            "culture": "Secondary",
            "isArchMaterial": False,
            "caches": [],
        })

    for a in artefacts:
        a["id"] = item_id_map.get(a["damagedName"]) or item_id_map.get(a["name"])

    mat_ids = sum(1 for m in materials if m["id"] is not None)
    art_ids = sum(1 for a in artefacts if a["id"] is not None)
    print(f"      -> Resolved {mat_ids}/{len(materials)} material IDs and {art_ids}/{len(artefacts)} artefact IDs.")


# ============================================================================
# 5. Scrape Collections, Collector NPC Locations & Dynamic Reward Metadata
# ============================================================================

def scrape_relic_powers_by_item() -> tuple[dict[str, str], dict[str, str]]:
    """
    Scrapes https://runescape.wiki/w/Relic_powers?action=raw to dynamically map:
      - item_name_lower -> 'Relic: <Name> (<Effect>)'
      - collection_name_lower -> 'Relic: <Name> (<Effect>)'
    """
    relic_by_item: dict[str, str] = {}
    relic_by_collection: dict[str, str] = {}
    raw = fetch_wiki_raw("Relic_powers")

    for row in re.split(r"(?m)^\|-", raw):
        lines = [ln.strip() for ln in row.splitlines() if ln.strip().startswith("|")]
        if len(lines) < 7:
            continue

        # Line 1: | [[Relic Power Name]]
        name_m = re.search(r"\[\[(?:[^\]|]+\|)?([^\]]+)\]\]", lines[1])
        if not name_m:
            continue
        relic_name = clean_wiki_text(name_m.group(1))
        if not relic_name or "File:" in lines[1]:
            continue

        effect = clean_wiki_text(lines[2].lstrip("|").strip())
        # Shorten effect to first sentence so it fits cleanly in UI table and tooltips
        short_effect = re.split(r"\.\s+|\s*\(", effect)[0].rstrip(".")
        label = f"Relic: {relic_name} ({short_effect})" if short_effect else f"Relic: {relic_name}"

        relic_by_item[relic_name.lower()] = label

        # Line 6: Required relic column (contains {{plinkt|Item}} and optional [[component item]])
        req_cell = lines[6]
        for pm in re.finditer(r"\{\{plinkt?\|([^}|]+)", req_cell, flags=re.IGNORECASE):
            item_name = clean_wiki_text(pm.group(1))
            if item_name:
                relic_by_item[item_name.lower()] = label
        for lm in re.finditer(r"\[\[(?:[^\]|]+\|)?([^\]]+)\]\]", req_cell):
            sub_item = clean_wiki_text(lm.group(1))
            if sub_item and not sub_item.lower().startswith("file:"):
                relic_by_item[sub_item.lower()] = label

        # Check for {{Collections value|<CollectionName>}} in the row
        for cm in re.finditer(r"\{\{Collections value\|([^}|]+)", row, flags=re.IGNORECASE):
            col_name = clean_wiki_text(cm.group(1))
            if col_name:
                relic_by_collection[col_name.lower()] = label

    return relic_by_item, relic_by_collection


def scrape_reward_item_classifications(
    reward_items: list[str],
    relic_by_item: dict[str, str],
) -> dict[str, tuple[str, str]]:
    """
    Dynamically queries the RuneScape Wiki pages of collection one-time reward items
    to determine whether each item unlocks a Relic Power, Weapon Piece, or Mystery.
    """
    classifications: dict[str, tuple[str, str]] = {}
    to_query: list[str] = []

    for item in reward_items:
        if not item:
            continue
        clean_item = re.sub(r"^\d+\s*[x\u00d7]\s*", "", item).strip()
        if not clean_item or clean_item.lower() in ("none", "n/a"):
            continue
        lower_clean = clean_item.lower()
        if lower_clean in relic_by_item:
            classifications[lower_clean] = ("relic", relic_by_item[lower_clean])
            continue
        if any(k in lower_clean for k in ("chronotes", "tetracompass", "artefact", "lamp", "tome", "battery", "batteries")):
            continue
        to_query.append(clean_item)

    pages = query_pages_wikitext(to_query)

    for clean_item in set(to_query):
        wt = pages.get(clean_item, "")
        lower_item = clean_item.lower()
        if not wt:
            continue

        # 1. Check if the item's Wiki page unlocks a Relic Power or thermal bath effect
        relic_m = re.search(
            r"unlock(?:s|ing)? (?:the )?\[\[([^\]|#]+?)(?:\s*\(relic power\))?(?:\|([^\]]+))?\]\]\s*\[\[relic power\]\]"
            r"|unlock(?:s|ing)? (?:the )?\[\[([^\]|#]+?)\s*\(relic power\)(?:\|([^\]]+))?\]\]"
            r"|\{\{Relics\}\}",
            wt,
            flags=re.IGNORECASE,
        )
        if relic_m:
            matched_relic = ""
            if relic_m.lastindex:
                for g_idx in range(1, (relic_m.lastindex or 0) + 1):
                    if relic_m.group(g_idx):
                        matched_relic = clean_wiki_text(relic_m.group(g_idx))
                        break
            if matched_relic and matched_relic.lower() in relic_by_item:
                classifications[lower_item] = ("relic", relic_by_item[matched_relic.lower()])
            else:
                for r_key, r_desc in relic_by_item.items():
                    if re.search(rf"\b{re.escape(r_key)}\b", wt, re.IGNORECASE):
                        classifications[lower_item] = ("relic", r_desc)
                        break
                if lower_item not in classifications:
                    classifications[lower_item] = ("relic", f"Relic: {matched_relic or clean_item}")
            continue

        # 2. Check if the item is a piece of the Inquisitor staff or Spear of Annihilation
        if re.search(r"\[\[Inquisitor staff\]\]|Inquisitor's staff", wt, re.IGNORECASE):
            classifications[lower_item] = ("weapon", "T97 Weapon: Inquisitor Staff Piece")
            continue

        # 3. Check if the item unlocks a Mystery / Dig Site feature
        mys_m = re.search(
            r"\[\[([^\]|#]+?)\s*\(mystery\)(?:\|([^\]]+))?\]\]",
            wt,
            flags=re.IGNORECASE,
        )
        if mys_m or re.search(r"\[\[Mysteries\]\]|\[\[Mystery\]\]|blueprint|monolith|mystery", wt, re.IGNORECASE):
            if mys_m:
                mys_name = clean_wiki_text(mys_m.group(2) or mys_m.group(1))
                classifications[lower_item] = ("mystery", f"Mystery: {mys_name} ({clean_item})")
            else:
                classifications[lower_item] = ("mystery", f"Mystery Unlock: {clean_item}")

    return classifications


def scrape_collector_locations(collector_names: list[str], collections_raw: str) -> dict[str, str]:
    """
    Extracts each collector's hand-in location directly from the `==Collector==` sections
    of `Collections?action=raw`, falling back to their NPC infobox if needed.
    """
    locations: dict[str, str] = {}

    # 1. Parse `==Collector Name==` lead sentences on `Collections?action=raw`
    for sec_m in re.finditer(r"==\s*([^=\n]+?)\s*==\n+([^\n]+)", collections_raw):
        sec_title = clean_wiki_text(sec_m.group(1))
        lead_line = clean_wiki_text(sec_m.group(2))
        loc_m = re.search(
            r"can be found (?:on at |on |in |at )(?:the )?(.+?)(?:\s+where (?:he|she|they) will take|\.\s*$)",
            lead_line,
            flags=re.IGNORECASE,
        )
        if loc_m:
            loc_clean = loc_m.group(1).strip()
            if loc_clean:
                loc_clean = loc_clean[0].upper() + loc_clean[1:]
                locations[sec_title] = loc_clean

    # 2. Match against full collector names from the overview table (e.g. "Soran, Emissary of Zaros" -> "Soran")
    missing_collectors: list[str] = []
    for name in sorted(set(collector_names)):
        if name in locations:
            continue
        short_name = name.split(",")[0].strip()
        if short_name in locations:
            locations[name] = locations[short_name]
        else:
            missing_collectors.append(name)

    # 3. Query NPC infoboxes for any remaining collectors
    if missing_collectors:
        pages = query_pages_wikitext(missing_collectors)
        for name in missing_collectors:
            wt = pages.get(name, "")
            loc = extract_infobox_param(wt, ["location", "locations", "area"])
            if loc:
                loc = re.sub(r"\s*,\s*surface world.*$", "", loc, flags=re.IGNORECASE)
                locations[name] = loc
            else:
                locations[name] = "Archaeology Campus"

    return locations


def scrape_collections() -> tuple[list[dict[str, Any]], dict[str, str]]:
    print("[5/5] Fetching Collections, Relic_powers, and Collector NPC locations from RuneScape Wiki...")
    col_html = fetch_wiki_html("Collections")
    col_raw = fetch_wiki_raw("Collections")

    overview: dict[str, dict[str, Any]] = {}
    collector_names: list[str] = []
    reward_items_to_classify: list[str] = []

    table_m = re.search(r'(?s)<table[^>]+data-tableid="Achievements list"[^>]*>(.*?)</table>', col_html)
    if table_m:
        for r in re.finditer(r"(?s)<tr[^>]*>(.*?)</tr>", table_m.group(1)):
            cells = [c.group(1) for c in re.finditer(r"(?s)<td[^>]*>(.*?)</td>", r.group(1))]
            if len(cells) < 8:
                continue

            lvl_str = strip_tags_and_decode(cells[0])
            col_name = strip_tags_and_decode(cells[1])
            collector = strip_tags_and_decode(cells[2])
            one_time = strip_tags_and_decode(cells[3])
            if one_time == "N/A":
                one_time = ""
            recurring = strip_tags_and_decode(cells[4])
            if recurring == "N/A":
                recurring = ""
            chronotes = strip_tags_and_decode(cells[5])
            rep_str = strip_tags_and_decode(cells[6])
            is_rep = rep_str.lower() == "yes"
            ach_m = re.search(r'data-rowid="(\d+)"', r.group(0))
            ach_id = int(ach_m.group(1)) if ach_m else None

            if not lvl_str.isdigit() or not col_name:
                continue

            if collector and collector not in collector_names:
                collector_names.append(collector)
            if one_time:
                reward_items_to_classify.append(one_time)

            overview[col_name] = {
                "level": int(lvl_str),
                "name": col_name,
                "collector": collector,
                "oneTimeReward": one_time,
                "recurringReward": recurring,
                "chronotes": chronotes,
                "isRepeatable": is_rep,
                "achievementId": ach_id,
            }

    relic_by_item, relic_by_collection = scrape_relic_powers_by_item()
    reward_classifications = scrape_reward_item_classifications(reward_items_to_classify, relic_by_item)

    sections = re.split(r'(?=<table[^>]+data-tableid="Archaeology Collection - )', col_html)
    collections_list: list[dict[str, Any]] = []

    for sec in sections[1:]:
        m_name = re.search(r'data-tableid="Archaeology Collection - ([^"]+)"', sec)
        if not m_name:
            continue

        c_name = html.unescape(m_name.group(1).strip())
        req_arts: list[str] = []
        for ar in re.finditer(r'(?s)<tr data-rowid="([^"]+)">\s*<td>\s*(\d+)\s*</td>', sec):
            art_name = html.unescape(ar.group(1).strip())
            if art_name and art_name not in req_arts:
                req_arts.append(art_name)

        info = overview.get(c_name, {})
        lvl = info.get("level", 0)
        collector = info.get("collector", "Unknown")
        one_time = info.get("oneTimeReward", "")
        recurring = info.get("recurringReward", "")
        chronotes = info.get("chronotes", "")
        is_rep = info.get("isRepeatable", True)
        ach_id = info.get("achievementId")

        clean_one_time = re.sub(r"^\d+\s*[x\u00d7]\s*", "", one_time).strip().lower()
        benefit_type = ""
        special_benefit = ""

        if c_name.lower() in relic_by_collection:
            benefit_type = "relic"
            special_benefit = relic_by_collection[c_name.lower()]
        elif clean_one_time in reward_classifications:
            benefit_type, special_benefit = reward_classifications[clean_one_time]
        else:
            for item_key, (b_type, b_desc) in reward_classifications.items():
                if item_key and (item_key in one_time.lower() or item_key in recurring.lower()):
                    benefit_type, special_benefit = b_type, b_desc
                    break

        if not benefit_type and "tetracompass piece" in recurring.lower():
            benefit_type = "tetra"
            special_benefit = "Tetracompass Piece Farm"

        collections_list.append({
            "name": c_name,
            "level": lvl,
            "collector": collector,
            "oneTimeReward": one_time,
            "recurringReward": recurring,
            "chronotes": chronotes,
            "isRepeatable": is_rep,
            "achievementId": ach_id,
            "benefitType": benefit_type,
            "specialBenefit": special_benefit,
            "artefacts": req_arts,
        })

    collections_list.sort(key=lambda c: (c["level"], c["name"]))
    collector_locations = scrape_collector_locations(collector_names, col_raw)
    print(
        f"      -> Parsed {len(collections_list)} collections and "
        f"{len(collector_locations)} collector hand-in locations."
    )
    return collections_list, collector_locations


# ============================================================================
# Lua Code Generators (DRY, using core/utils)
# ============================================================================

def generate_materials_lua(materials: list[dict[str, Any]]) -> str:
    lines = [
        "-- data/materials.lua",
        "-- Auto-generated by scripts/update_wiki_data.py from official RuneScape Wiki data.",
        "-- Do not edit the LIST table manually; re-run `python scripts/update_wiki_data.py` after game updates.",
        "",
        'local Utils = require("core/utils")',
        "",
        "local Materials = {}",
        "",
        "Materials.LIST = {",
    ]
    for m in materials:
        id_val = m["id"] if m["id"] is not None else "nil"
        is_arch = "true" if m["isArchMaterial"] else "false"
        caches_str = ", ".join(f'"{escape_lua(c)}"' for c in m["caches"])
        caches_lua = f"{{ {caches_str} }}" if caches_str else "{}"
        lines.append(
            f'    {{ id = {id_val}, name = "{escape_lua(m["name"])}", level = {m["level"]}, '
            f'culture = "{escape_lua(m["culture"])}", isArchMaterial = {is_arch}, caches = {caches_lua} }},'
        )
    lines.extend([
        "}",
        "",
        "Materials.BY_NAME = {}",
        "Materials.BY_LOWER = {}",
        "Materials.BY_ID = {}",
        "",
        "for idx, mat in ipairs(Materials.LIST) do",
        "    mat.order = idx",
        "    Materials.BY_NAME[mat.name] = mat",
        "    Materials.BY_LOWER[Utils.normalizeName(mat.name)] = mat",
        "    if mat.id then",
        "        Materials.BY_ID[mat.id] = mat",
        "    end",
        "end",
        "",
        "function Materials.normalize(name)",
        "    return Utils.normalizeName(name)",
        "end",
        "",
        "function Materials.get(name)",
        "    if not name then return nil end",
        "    return Materials.BY_NAME[name] or Materials.BY_LOWER[Utils.normalizeName(name)]",
        "end",
        "",
        "function Materials.getById(id)",
        "    if not id then return nil end",
        "    return Materials.BY_ID[id]",
        "end",
        "",
        "function Materials.isMaterial(name)",
        "    return Materials.get(name) ~= nil",
        "end",
        "",
        "function Materials.isArchMaterial(name)",
        "    local m = Materials.get(name)",
        "    return m ~= nil and m.isArchMaterial == true",
        "end",
        "",
        "return Materials",
        "",
    ])
    return "\n".join(lines)


def generate_artefacts_lua(artefacts: list[dict[str, Any]]) -> str:
    lines = [
        "-- data/artefacts.lua",
        "-- Auto-generated by scripts/update_wiki_data.py from official RuneScape Wiki data.",
        "-- Do not edit the LIST table manually; re-run `python scripts/update_wiki_data.py` after game updates.",
        "",
        'local Utils = require("core/utils")',
        "",
        "local Artefacts = {}",
        "",
        "Artefacts.LIST = {",
    ]
    for a in artefacts:
        mats_str = ", ".join(
            f'{{ name = "{escape_lua(r["name"])}", count = {r["count"]} }}'
            for r in a["materials"]
        )
        id_val = a["id"] if a["id"] is not None else "nil"
        lines.extend([
            "    {",
            f"        id = {id_val},",
            f'        name = "{escape_lua(a["name"])}",',
            f'        damagedName = "{escape_lua(a["damagedName"])}",',
            f"        level = {a['level']},",
            f'        location = "{escape_lua(a["location"])}",',
            f"        xp = {a['xp']},",
            f"        chronotes = {a['chronotes']},",
            f"        materials = {{ {mats_str} }}",
            "    },",
        ])

    lines.extend([
        "}",
        "",
        "Artefacts.BY_DAMAGED_LOWER = {}",
        "Artefacts.BY_BASE_LOWER = {}",
        "Artefacts.BY_ID = {}",
        "",
        "for idx, art in ipairs(Artefacts.LIST) do",
        "    art.order = idx",
        "    Artefacts.BY_DAMAGED_LOWER[Utils.normalizeName(art.damagedName)] = art",
        "    Artefacts.BY_BASE_LOWER[Utils.normalizeName(art.name)] = art",
        "    if art.id then",
        "        Artefacts.BY_ID[art.id] = art",
        "    end",
        "end",
        "",
        "function Artefacts.normalize(name)",
        "    return Utils.normalizeName(name)",
        "end",
        "",
        "function Artefacts.findById(id)",
        "    if not id then return nil end",
        "    return Artefacts.BY_ID[id]",
        "end",
        "",
        "function Artefacts.findByName(rawName)",
        '    if not rawName or rawName == "" then return nil end',
        "    local norm = Utils.normalizeName(rawName)",
        "    local exact = Artefacts.BY_DAMAGED_LOWER[norm]",
        "    if exact then",
        "        return exact, true",
        "    end",
        "    local base, isDamagedSuffix = Utils.extractDamagedBaseName(rawName)",
        "    if isDamagedSuffix then",
        "        local byBase = Artefacts.BY_BASE_LOWER[base]",
        "        if byBase then return byBase, true end",
        "    else",
        "        local byRestored = Artefacts.BY_BASE_LOWER[base]",
        "        if byRestored then return byRestored, false end",
        "    end",
        "    return nil",
        "end",
        "",
        "function Artefacts.findRestoredByName(rawName)",
        '    if not rawName or rawName == "" then return nil end',
        "    return Artefacts.BY_BASE_LOWER[Utils.normalizeName(rawName)]",
        "end",
        "",
        "function Artefacts.findByObj(obj)",
        "    if not obj then return nil end",
        "    local okName, name = pcall(function() return obj.name end)",
        '    if not okName or not name or name == "" then return nil end',
        "    return Artefacts.findByName(name)",
        "end",
        "",
        "return Artefacts",
        "",
    ])
    return "\n".join(lines)


def generate_hotspots_lua(hotspot_materials_by_spot: dict[str, dict[str, Any]]) -> str:
    lines = [
        "-- data/hotspots.lua",
        "-- Auto-generated by scripts/update_wiki_data.py from official RuneScape Wiki data.",
        "-- Maps active Excavation Hotspot world names to their yielded restoration materials.",
        "",
        'local Utils = require("core/utils")',
        "",
        "local Hotspots = {}",
        "",
        "Hotspots.BY_NAME = {",
    ]
    sorted_spots = sorted(
        hotspot_materials_by_spot.items(),
        key=lambda kv: (kv[1]["level"], kv[0]),
    )
    for spot_name, info in sorted_spots:
        mats_str = ", ".join(f'"{escape_lua(m)}"' for m in info["materials"])
        mats_lua = f"{{ {mats_str} }}" if mats_str else "{}"
        lines.append(
            f'    ["{escape_lua(spot_name)}"] = {{ level = {info["level"]}, materials = {mats_lua} }},'
        )

    lines.extend([
        "}",
        "",
        "Hotspots.BY_LOWER = {}",
        "for name, data in pairs(Hotspots.BY_NAME) do",
        "    Hotspots.BY_LOWER[Utils.normalizeName(name)] = data",
        "end",
        "",
        "function Hotspots.get(name)",
        "    if not name then return nil end",
        "    local direct = Hotspots.BY_NAME[name]",
        "    if direct then return direct end",
        "    local cleaned = Utils.cleanText(name)",
        "    if cleaned ~= name and Hotspots.BY_NAME[cleaned] then",
        "        return Hotspots.BY_NAME[cleaned]",
        "    end",
        "    return Hotspots.BY_LOWER[Utils.normalizeName(cleaned)]",
        "end",
        "",
        "function Hotspots.findMatch(rawName)",
        "    if not rawName then return nil end",
        "    local exact = Hotspots.get(rawName)",
        "    if exact then return exact, rawName end",
        "    local cleaned = Utils.cleanText(rawName)",
        "    local lowerClean = Utils.normalizeName(cleaned)",
        "    for name, data in pairs(Hotspots.BY_NAME) do",
        "        local lowerKey = string.lower(name)",
        "        if lowerClean == lowerKey or string.find(lowerClean, lowerKey, 1, true) then",
        "            return data, name",
        "        end",
        "    end",
        "    return nil, cleaned",
        "end",
        "",
        "return Hotspots",
        "",
    ])
    return "\n".join(lines)


def generate_collections_lua(
    collections_list: list[dict[str, Any]],
    collector_locations: dict[str, str],
) -> str:
    lines = [
        "-- data/collections.lua",
        "-- Auto-generated by scripts/update_wiki_data.py from official RuneScape Wiki data.",
        "-- Contains all Archaeology collections, collector hand-in locations, required artefacts, and rewards.",
        "",
        'local Utils = require("core/utils")',
        "",
        "local Collections = {}",
        "",
        "-- Collector hand-in locations dynamically scraped from Collector NPC Wiki pages",
        "Collections.COLLECTOR_LOCATIONS = {",
    ]
    for collector_name in sorted(collector_locations.keys()):
        loc = collector_locations[collector_name]
        lines.append(f'    ["{escape_lua(collector_name)}"] = "{escape_lua(loc)}",')
    lines.extend([
        "}",
        "",
        "function Collections.getCollectorLocation(collectorName)",
        '    if not collectorName then return "Archaeology Campus" end',
        '    return Collections.COLLECTOR_LOCATIONS[collectorName] or "Archaeology Campus"',
        "end",
        "",
        "Collections.LIST = {",
    ])

    for idx, col in enumerate(collections_list, start=1):
        arts_str = ", ".join(f'"{escape_lua(a)}"' for a in col["artefacts"])
        is_rep_lua = "true" if col.get("isRepeatable", True) else "false"
        ach_id = col.get("achievementId")
        col_lines = [
            "    {",
            f"        order = {idx},",
            f'        name = "{escape_lua(col["name"])}",',
            f"        level = {col['level']},",
            f'        collector = "{escape_lua(col["collector"])}",',
            f'        oneTimeReward = "{escape_lua(col["oneTimeReward"])}",',
            f'        recurringReward = "{escape_lua(col["recurringReward"])}",',
            f'        chronotes = "{escape_lua(col["chronotes"])}",',
            f"        isRepeatable = {is_rep_lua},",
        ]
        if ach_id is not None:
            col_lines.append(f"        achievementId = {ach_id},")
        col_lines.extend([
            f'        benefitType = "{escape_lua(col["benefitType"])}",',
            f'        specialBenefit = "{escape_lua(col["specialBenefit"])}",',
            f"        artefacts = {{ {arts_str} }}",
            "    },",
        ])
        lines.extend(col_lines)

    lines.extend([
        "}",
        "",
        "Collections.BY_NAME = {}",
        "Collections.BY_LOWER = {}",
        "Collections.BY_ARTEFACT_LOWER = {}",
        "",
        "for _, col in ipairs(Collections.LIST) do",
        "    col.location = Collections.getCollectorLocation(col.collector)",
        "    Collections.BY_NAME[col.name] = col",
        "    Collections.BY_LOWER[Utils.normalizeName(col.name)] = col",
        "    for _, artName in ipairs(col.artefacts) do",
        "        local key = Utils.normalizeName(artName)",
        "        if not Collections.BY_ARTEFACT_LOWER[key] then",
        "            Collections.BY_ARTEFACT_LOWER[key] = {}",
        "        end",
        "        table.insert(Collections.BY_ARTEFACT_LOWER[key], col)",
        "    end",
        "end",
        "",
        "function Collections.getCollectionsForArtefact(artName)",
        "    if not artName then return nil end",
        "    return Collections.BY_ARTEFACT_LOWER[Utils.normalizeName(artName)]",
        "end",
        "",
        "return Collections",
        "",
    ])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Scrape RuneScape Wiki and update Lua data tables.")
    parser.add_argument("--dry-run", action="store_true", help="Parse and validate without writing files.")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    data_dir = repo_root / "data"

    materials, arch_mat_names = scrape_materials()
    artefacts, secondary_items = scrape_artefacts(arch_mat_names)
    hotspot_materials_by_spot = scrape_excavation_hotspots(artefacts)
    resolve_all_item_ids(materials, secondary_items, artefacts)
    collections_list, collector_locations = scrape_collections()

    if args.dry_run:
        print(
            f"[DryRun] Successfully scraped {len(materials)} materials, "
            f"{len(artefacts)} artefacts, {len(hotspot_materials_by_spot)} hotspots, "
            f"{len(collections_list)} collections, and {len(collector_locations)} collector locations."
        )
        return 0

    data_dir.mkdir(parents=True, exist_ok=True)
    files_to_write = {
        data_dir / "materials.lua": generate_materials_lua(materials),
        data_dir / "artefacts.lua": generate_artefacts_lua(artefacts),
        data_dir / "hotspots.lua": generate_hotspots_lua(hotspot_materials_by_spot),
        data_dir / "collections.lua": generate_collections_lua(collections_list, collector_locations),
    }

    for path, content in files_to_write.items():
        path.write_text(content, encoding="utf-8", newline="\n")
        print(f"[Saved] {path.relative_to(repo_root)} ({len(content):,} bytes)")

    print("[Success] All Archaeology Assistant data modules updated from official RuneScape Wiki!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
