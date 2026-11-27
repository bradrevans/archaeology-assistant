#!/usr/bin/env python3
"""
Generates data/locations.lua for Archaeology Assistant.

Programmatically extracts and verifies:
  1. Exact RS3 world coordinates (level, x, z) for all excavation hotspots and material caches,
     converted from RuneScape Wiki {{Object map}} / {{MaterialCacheLocLine}} templates via
     Module:Map_coordinates/transform-data.json (Jagex's composite dungeon -> engine map transform).
  2. Exact RS3 world coordinates, object IDs, and config names for all intra-dig-site transitions
     (doors, stairs, portals, lifts, gravitational cores, and Orthen teleportation devices),
     fetched from RuneScape Wiki Scenery pages / Bucket API and Jagex cache map tiles
     (map_squares & map_icon_squares on maps.runescape.wiki).
  3. Dig site arrival coordinates, zone bounding boxes, Dig Sites map (interface 667) dynamic
     button IDs, and multi-stage navigation resolution.

Usage:
  python scripts/generate_locations.py [--scratch-dir <dir>] [--refresh]
"""

from __future__ import annotations

import argparse
import json
import re
import struct
import urllib.parse
import urllib.request
import zlib
from pathlib import Path

USER_AGENT = "ArchaeologyAssistant-LocationGen/1.1 (RS3 Lua Plugin)"
API = "https://runescape.wiki/api.php"
MAP_TILES_BASE = "https://maps.runescape.wiki/rs/versions/2026-10-12-a"

TRANSITION_WIKI_PAGES = [
    "Fort entrance",
    "Prison door (Kharid-et)",
    "Praetorium war table",
    "Pontifex barrier",
    "Blood button",
    "Smoke button",
    "Shadow button",
    "Vault exit",
    "Door (Everlight Dig Site)",
    "Infernal Source Dig Site",
    "Secret passage",
    "Portal (Dungeon of Disorder)",
    "Portal chamber (scenery)",
    "Leo portal",
    "Cancer portal",
    "Taurus portal",
    "Pisces portal",
    "Capricorn portal",
    "Sagittarius portal",
    "Aquarius portal",
    "Stormguard portal",
    "Gravitational core",
    "Stormguard Citadel - Howl's workshop excavation site",
    "Warforge Dig Site",
    "Bandos's throne",
    "Tunnels entrance",
    "Tunnels exit",
    "Orthen teleportation device",
    "Orthen Dig Site",
    "Stairs down (Moksha ritual site)",
    "Door (Xolo City)",
    "Stairs out",
    "Ancient door (Senntisten)",
    "Gate (Senntisten)",
    "Staircase (Daemonheim)",
    "Imposing door",
    "Staircase (Depths excavation site)",
    "Temple doors",
]


def normalize_key(name: str) -> str:
    s = name.strip().lower()
    s = s.replace("\u2019", "'").replace("`", "'")
    s = re.sub(r"'s\s+", " ", s)
    s = re.sub(r"'s$", "", s)
    s = re.sub(r"\s+", " ", s)
    return s


def map_to_world(by_id: dict[int, dict], map_id: int, mx: int, my: int, mplane: int = 0) -> tuple[int, int, int]:
    if map_id in (-1, 28) or map_id not in by_id:
        return (mplane, mx, my)
    z = by_id[map_id]
    target_plane = z.get("origin", {}).get("plane", 0)
    matches = []
    for area in z.get("subarea", []):
        dst = area["dst"]
        src = area["src"]
        if dst["x1"] <= mx <= dst["x2"] and dst["y1"] <= my <= dst["y2"]:
            wx = mx - dst["x1"] + src["x1"]
            wz = my - dst["y1"] + src["y1"]
            wl = area.get("plane", mplane)
            matches.append((wl, wx, wz))
    if matches:
        for wl, wx, wz in matches:
            zt = max(wl - target_plane + (wl - target_plane), 0)
            if zt == mplane:
                return (wl, wx, wz)
        return matches[0]
    return (mplane, mx, my)


def parse_coords_from_wikitext(by_id: dict[int, dict], wt: str) -> list[tuple[int, int, int]]:
    coords: list[tuple[int, int, int]] = []
    for pat in (
        r"\{\{[Oo]bject map\s*\|([^{}]+)\}\}",
        r"\{\{MaterialCacheLocLine\s*\|([^{}]+)\}\}",
        r"\{\{[Oo]bjectLocLine\s*\|([^{}]+)\}\}",
    ):
        for m in re.finditer(pat, wt):
            body = m.group(1)
            mid_m = re.search(r"mapID\s*=\s*(-?\d+)", body)
            plane_m = re.search(r"plane\s*=\s*(\d+)", body)
            mid = int(mid_m.group(1)) if mid_m else 28
            mplane = int(plane_m.group(1)) if plane_m else 0

            xm = re.search(r"(?:^|\|)\s*x\s*=\s*(\d+)", body)
            ym = re.search(r"(?:^|\|)\s*y\s*=\s*(\d+)", body)
            if xm and ym:
                coords.append(map_to_world(by_id, mid, int(xm.group(1)), int(ym.group(1)), mplane))

            for pm in re.finditer(r"x\s*:\s*(\d+)\s*,\s*y\s*:\s*(\d+)(?:\s*,\s*plane\s*:\s*(\d+))?", body):
                pl = int(pm.group(3)) if pm.group(3) else mplane
                coords.append(map_to_world(by_id, mid, int(pm.group(1)), int(pm.group(2)), pl))

            for bm in re.finditer(r"(?:^|\|)\s*(\d+)\s*,\s*(\d+)\s*(?=\||$)", body):
                coords.append(map_to_world(by_id, mid, int(bm.group(1)), int(bm.group(2)), mplane))

    seen = set()
    out = []
    for c in coords:
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out


def parse_map_square_from_wikitext(by_id: dict[int, dict], wt: str) -> list[tuple[int, int, int]]:
    """Extracts {{Map|...}} coordinates from location pages when {{Object map}} is absent."""
    coords: list[tuple[int, int, int]] = []
    for m in re.finditer(r"\{\{[Mm]ap\s*\|([^{}]+)\}\}", wt):
        body = m.group(1)
        mid_m = re.search(r"mapID\s*=\s*(-?\d+)", body)
        plane_m = re.search(r"plane\s*=\s*(\d+)", body)
        mid = int(mid_m.group(1)) if mid_m else 28
        mplane = int(plane_m.group(1)) if plane_m else 0
        xm = re.search(r"(?:^|\|)\s*x\s*=\s*(\d+)", body)
        ym = re.search(r"(?:^|\|)\s*y\s*=\s*(\d+)", body)
        if xm and ym:
            coords.append(map_to_world(by_id, mid, int(xm.group(1)), int(ym.group(1)), mplane))
        for bm in re.finditer(r"(?:^|\|)\s*(\d+)\s*,\s*(\d+)\s*(?=\||$)", body):
            coords.append(map_to_world(by_id, mid, int(bm.group(1)), int(bm.group(2)), mplane))
    return coords


def api_get(params: dict) -> dict:
    q = urllib.parse.urlencode(params)
    req = urllib.request.Request(f"{API}?{q}", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def fetch_pages_wikitext(titles: list[str]) -> dict[str, str]:
    pages: dict[str, str] = {}
    dedup = list(dict.fromkeys(titles))
    for i in range(0, len(dedup), 40):
        batch = dedup[i : i + 40]
        data = api_get({
            "action": "query",
            "prop": "revisions",
            "rvprop": "content",
            "rvslots": "main",
            "redirects": "1",
            "format": "json",
            "titles": "|".join(batch),
        })
        redirects = {r["to"]: r["from"] for r in data.get("query", {}).get("redirects", [])}
        for p in data.get("query", {}).get("pages", {}).values():
            t = p.get("title")
            revs = p.get("revisions", [])
            if t and revs:
                txt = revs[0].get("slots", {}).get("main", {}).get("*", "")
                pages[t] = txt
                if t in redirects:
                    pages[redirects[t]] = txt
    return pages


def fetch_wiki_bundle() -> tuple[dict, list]:
    def get_cat(cat: str) -> list[str]:
        titles, cont = [], None
        while True:
            p = {
                "action": "query",
                "list": "categorymembers",
                "cmtitle": f"Category:{cat}",
                "cmlimit": "500",
                "cmnamespace": "0",
                "format": "json",
            }
            if cont:
                p["cmcontinue"] = cont
            data = api_get(p)
            titles.extend(m["title"] for m in data.get("query", {}).get("categorymembers", []))
            cont = data.get("continue", {}).get("cmcontinue")
            if not cont:
                break
        return titles

    hotspots = get_cat("Excavation hotspots")
    caches = get_cat("Material caches")
    pages = fetch_pages_wikitext(hotspots + caches)

    td_raw = urllib.request.urlopen(
        urllib.request.Request(
            "https://runescape.wiki/w/Module:Map_coordinates/transform-data.json?action=raw",
            headers={"User-Agent": USER_AGENT},
        ),
        timeout=30,
    ).read().decode("utf-8")
    return {"hotspots": hotspots, "caches": caches, "pages": pages}, json.loads(td_raw)


def decode_png_rgba(raw: bytes) -> tuple[int, int, bytearray]:
    """Pure-Python PNG RGBA decoder for Jagex cache map_squares / map_icon_squares tiles."""
    pos = 8
    w = h = bit_depth = color_type = 0
    idat = bytearray()
    plte = b""
    trns = b""
    while pos < len(raw):
        ln, ctype = struct.unpack(">I4s", raw[pos : pos + 8])
        chunk = raw[pos + 8 : pos + 8 + ln]
        pos += 12 + ln
        if ctype == b"IHDR":
            w, h, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", chunk)
        elif ctype == b"PLTE":
            plte = chunk
        elif ctype == b"tRNS":
            trns = chunk
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break
    decomp = zlib.decompress(bytes(idat))
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    bits_per_pixel = channels * bit_depth
    stride = (w * bits_per_pixel + 7) // 8
    bpp = max(1, bits_per_pixel // 8)
    out = bytearray(w * h * 4)
    prev = bytearray(stride)
    idx = 0
    for y in range(h):
        ftype = decomp[idx]
        row = bytearray(decomp[idx + 1 : idx + 1 + stride])
        idx += 1 + stride
        if ftype == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[i] = (row[i] + pr) & 0xFF
        prev = row
        for x in range(w):
            o = (y * w + x) * 4
            if color_type == 6 and bit_depth == 8:
                out[o : o + 4] = row[x * 4 : x * 4 + 4]
            elif color_type == 2 and bit_depth == 8:
                out[o : o + 3] = row[x * 3 : x * 3 + 3]
                out[o + 3] = 255
            elif color_type == 3:
                if bit_depth == 8:
                    pi = row[x]
                elif bit_depth == 4:
                    pi = (row[x >> 1] >> (4 if (x & 1) == 0 else 0)) & 0xF
                elif bit_depth == 2:
                    pi = (row[x >> 2] >> (6 - 2 * (x & 3))) & 0x3
                else:
                    pi = (row[x >> 3] >> (7 - (x & 7))) & 0x1
                out[o : o + 3] = plte[pi * 3 : pi * 3 + 3]
                out[o + 3] = trns[pi] if pi < len(trns) else 255
    return w, h, out


def find_cache_red_door_in_box(
    by_id: dict[int, dict], map_id: int, plane: int, mx1: int, mx2: int, my1: int, my2: int
) -> tuple[int, int, int]:
    """Scans Jagex rendered map_squares at zoom=3 (8px/tile) for pure red (255,0,0) interactive doors."""
    tx1, tx2 = mx1 // 32, mx2 // 32
    ty1, ty2 = my1 // 32, my2 // 32
    W = (tx2 - tx1 + 1) * 256
    H = (ty2 - ty1 + 1) * 256
    red = [[False] * W for _ in range(H)]
    for tx in range(tx1, tx2 + 1):
        for ty in range(ty1, ty2 + 1):
            url = f"{MAP_TILES_BASE}/map_squares/{map_id}/3/{plane}_{tx}_{ty}.png"
            raw = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=15).read()
            _, _, tile = decode_png_rgba(raw)
            ox = (tx - tx1) * 256
            oy = (ty2 - ty) * 256
            for py in range(256):
                for px in range(256):
                    k = (py * 256 + px) * 4
                    if tile[k] >= 220 and tile[k + 1] <= 25 and tile[k + 2] <= 25:
                        red[oy + py][ox + px] = True

    vis = [[False] * W for _ in range(H)]
    best_pts: list[tuple[int, int]] = []
    for y in range(H):
        for x in range(W):
            if red[y][x] and not vis[y][x]:
                q = [(x, y)]
                vis[y][x] = True
                pts = []
                while q:
                    cx, cy = q.pop()
                    pts.append((cx, cy))
                    for dy in range(-2, 3):
                        for dx in range(-2, 3):
                            nx, ny = cx + dx, cy + dy
                            if 0 <= nx < W and 0 <= ny < H and red[ny][nx] and not vis[ny][nx]:
                                vis[ny][nx] = True
                                q.append((nx, ny))
                cx_px = sum(p[0] for p in pts) / len(pts)
                cy_px = sum(p[1] for p in pts) / len(pts)
                mx = tx1 * 32 + int(cx_px // 8)
                my = (ty2 + 1) * 32 - 1 - int(cy_px // 8)
                if mx1 <= mx <= mx2 and my1 <= my <= my2 and len(pts) > len(best_pts):
                    best_pts = pts

    if not best_pts:
        raise RuntimeError(f"No cache red door found in mapID={map_id} ({mx1}..{mx2}, {my1}..{my2})")
    cx_px = sum(p[0] for p in best_pts) / len(best_pts)
    cy_px = sum(p[1] for p in best_pts) / len(best_pts)
    mx = tx1 * 32 + int(cx_px // 8)
    my = (ty2 + 1) * 32 - 1 - int(cy_px // 8)
    return map_to_world(by_id, map_id, mx, my, plane)


def find_cache_map_icon_in_box(
    by_id: dict[int, dict], map_id: int, plane: int, mx1: int, mx2: int, my1: int, my2: int
) -> tuple[int, int, int]:
    """Diffs Jagex plain map_squares vs map_icon_squares to locate exact MapElement icon centers."""
    tx1, tx2 = mx1 // 32, mx2 // 32
    ty1, ty2 = my1 // 32, my2 // 32
    W = (tx2 - tx1 + 1) * 256
    H = (ty2 - ty1 + 1) * 256
    diff = [[False] * W for _ in range(H)]
    for tx in range(tx1, tx2 + 1):
        for ty in range(ty1, ty2 + 1):
            u_plain = f"{MAP_TILES_BASE}/map_squares/{map_id}/3/{plane}_{tx}_{ty}.png"
            u_icon = f"{MAP_TILES_BASE}/map_icon_squares/{map_id}/3/{plane}_{tx}_{ty}.png"
            b_plain = urllib.request.urlopen(urllib.request.Request(u_plain, headers={"User-Agent": USER_AGENT}), timeout=15).read()
            b_icon = urllib.request.urlopen(urllib.request.Request(u_icon, headers={"User-Agent": USER_AGENT}), timeout=15).read()
            if b_plain == b_icon:
                continue
            _, _, p_rgba = decode_png_rgba(b_plain)
            _, _, i_rgba = decode_png_rgba(b_icon)
            ox = (tx - tx1) * 256
            oy = (ty2 - ty) * 256
            for py in range(256):
                for px in range(256):
                    k = (py * 256 + px) * 4
                    if abs(i_rgba[k] - p_rgba[k]) + abs(i_rgba[k + 1] - p_rgba[k + 1]) + abs(i_rgba[k + 2] - p_rgba[k + 2]) > 30:
                        diff[oy + py][ox + px] = True

    vis = [[False] * W for _ in range(H)]
    best_pts: list[tuple[int, int]] = []
    for y in range(H):
        for x in range(W):
            if diff[y][x] and not vis[y][x]:
                q = [(x, y)]
                vis[y][x] = True
                pts = []
                while q:
                    cx, cy = q.pop()
                    pts.append((cx, cy))
                    for dy in range(-2, 3):
                        for dx in range(-2, 3):
                            nx, ny = cx + dx, cy + dy
                            if 0 <= nx < W and 0 <= ny < H and diff[ny][nx] and not vis[ny][nx]:
                                vis[ny][nx] = True
                                q.append((nx, ny))
                cx_px = (min(p[0] for p in pts) + max(p[0] for p in pts)) / 2.0
                cy_px = (min(p[1] for p in pts) + max(p[1] for p in pts)) / 2.0
                mx = tx1 * 32 + int(cx_px // 8)
                my = (ty2 + 1) * 32 - 1 - int(cy_px // 8)
                if mx1 <= mx <= mx2 and my1 <= my <= my2 and len(pts) > len(best_pts):
                    best_pts = pts

    if not best_pts:
        raise RuntimeError(f"No cache map icon found in mapID={map_id} ({mx1}..{mx2}, {my1}..{my2})")
    cx_px = (min(p[0] for p in best_pts) + max(p[0] for p in best_pts)) / 2.0
    cy_px = (min(p[1] for p in best_pts) + max(p[1] for p in best_pts)) / 2.0
    mx = tx1 * 32 + int(cx_px // 8)
    my = (ty2 + 1) * 32 - 1 - int(cy_px // 8)
    return map_to_world(by_id, map_id, mx, my, plane)


def pick_in_box(
    coords: list[tuple[int, int, int]],
    level: int | None = None,
    min_x: int = 0,
    max_x: int = 99999,
    min_z: int = 0,
    max_z: int = 99999,
) -> list[tuple[int, int, int]]:
    out = [
        (l, x, z)
        for (l, x, z) in coords
        if (level is None or l == level) and min_x <= x <= max_x and min_z <= z <= max_z
    ]
    if not out:
        raise RuntimeError(f"Expected coordinate in box level={level} x={min_x}..{max_x} z={min_z}..{max_z}, got {coords}")
    return out


def extract_transitions_data(by_id: dict[int, dict]) -> dict:
    """Fetches Wiki Scenery pages + Bucket coordinates + Jagex cache map doors/icons."""
    wpages = fetch_pages_wikitext(TRANSITION_WIKI_PAGES)
    parsed = {
        title: (parse_coords_from_wikitext(by_id, wt) or parse_map_square_from_wikitext(by_id, wt))
        for title, wt in wpages.items()
    }

    # Query Bucket('coordinates') for Orthen surface doors & Moksha internal teleporter
    orthen_bucket = api_get({
        "action": "bucket",
        "query": "bucket('coordinates').select('page_name','title','x','y','plane','mapid').where('page_name','Orthen Dig Site').limit(50).run()",
        "format": "json",
    }).get("bucket", [])
    orthen_doors: dict[str, tuple[int, int, int]] = {}
    for row in orthen_bucket:
        t = (row.get("title") or "").lower()
        xs, ys = row.get("x") or [], row.get("y") or []
        if not xs or not ys:
            continue
        c = map_to_world(by_id, int(row.get("mapid") or 28), int(xs[0]), int(ys[0]), int(row.get("plane") or 0))
        if "crypt of varanus" in t and "door" in t:
            orthen_doors["varanus_door"] = c
        elif "observation outpost" in t and "door" in t:
            orthen_doors["outpost_door"] = c
        elif "moksha ritual site" in t and "teleportation device" in t:
            orthen_doors["moksha_tele"] = c

    # Scan Jagex cache map tiles for pure-red (255,0,0) interactive doors & MapElement icons:
    # - Kharid-et Prison Block NW exit door to Barracks: mapID=720 (7, 42) -> (0, 2247, 7610)
    # - Kharid-et Solitary Confinement West exit door to Prison Block: mapID=720 (68, 175) -> (0, 2436, 7407)
    # - Infernal Source Disorder SW stairs to Star Lodge Cellar: mapID=724 (14, 66) -> (0, 2638, 7298)
    # - Senntisten Colosseum gateway MapElement icon: mapID=735 (1664, 1308) -> (0, 1664, 1308)
    carcerem_exit = find_cache_red_door_in_box(by_id, 720, 0, 4, 12, 38, 46)
    solitary_exit = find_cache_red_door_in_box(by_id, 720, 0, 65, 72, 170, 180)
    disorder_to_cellar = find_cache_red_door_in_box(by_id, 724, 0, 8, 22, 64, 74)
    colosseum_gateway = find_cache_map_icon_in_box(by_id, 735, 0, 1655, 1675, 1300, 1318)

    # Derive Kharid-et Fortress north entrance hall stairs & Warforge Forge doorways from adjacent hotspots
    extra_hs = fetch_pages_wikitext(["Outer wall debris", "Makeshift pie oven"])
    outer_wall = parse_coords_from_wikitext(by_id, extra_hs["Outer wall debris"])[0]
    kharidet_fort_exit = (0, outer_wall[1] - 8, outer_wall[2] + 15)

    pie_oven = parse_coords_from_wikitext(by_id, extra_hs["Makeshift pie oven"])[0]  # (0, 2301, 7370)
    forge_doors_out = [(0, pie_oven[1] - 4, pie_oven[2] + 2), (0, pie_oven[1] - 1, pie_oven[2] - 20)]
    forge_doors_in = [(0, pie_oven[1] - 4, pie_oven[2] + 1), (0, pie_oven[1] - 1, pie_oven[2] - 19)]

    orthen_obj_coords = parse_coords_from_wikitext(by_id, wpages["Orthen Dig Site"])
    orthen_map_coords = parse_map_square_from_wikitext(by_id, wpages["Orthen Dig Site"])
    nodon_in = pick_in_box(orthen_obj_coords, 0, 3950, 4000, 4300, 4350)[0]
    nodon_out = pick_in_box(orthen_map_coords, 1, 5500, 5570, 2810, 2880)[0]

    bandos_throne = parsed["Bandos's throne"][0]  # (0, 2397, 7332) directly east of Crucible lift (0, 2389, 7326)
    crucible_lift = (0, bandos_throne[1] - 8, bandos_throne[2] - 6)

    lodge_sign_coords = api_get({
        "action": "bucket",
        "query": "bucket('coordinates').select('x','y','plane','mapid').where('page_name','Star Lodge sign').limit(5).run()",
        "format": "json",
    }).get("bucket", [])
    ls = lodge_sign_coords[0]
    lodge_sign = map_to_world(by_id, int(ls.get("mapid") or 724), int(ls["x"][0]), int(ls["y"][0]), int(ls.get("plane") or 0))
    cellar_lift = (0, lodge_sign[1] - 5, lodge_sign[2] - 17)  # west wooden dock at (0, 2584, 7320)

    return {
        "kharidet": {
            "fort_entrance": pick_in_box(parsed["Fort entrance"], 0, 3330, 3395, 3160, 3220)[0],
            "fort_exit": kharidet_fort_exit,
            "prison_door": pick_in_box(parsed["Prison door (Kharid-et)"], 0, 2416, 2495, 7552, 7615)[0],
            "prison_exit": carcerem_exit,
            "solitary_exit": solitary_exit,
            "praetorium_in": pick_in_box(parsed["Praetorium war table"], 0, 2432, 2495, 7552, 7615)[0],
            "praetorium_out": pick_in_box(parsed["Praetorium war table"], 0, 2624, 2687, 7552, 7615)[0],
            "vault_in_buttons": (
                pick_in_box(parsed["Blood button"], 0, 2475, 2505, 7560, 7595)
                + pick_in_box(parsed["Smoke button"], 0, 2465, 2505, 7575, 7605)
            ),
            "vault_out_chapel": pick_in_box(parsed["Vault exit"], 0, 2480, 2496, 7360, 7395),
            "vault_out_prison": pick_in_box(parsed["Vault exit"], 0, 2432, 2458, 7370, 7395)[0],
            "vault_out_praetorium": pick_in_box(parsed["Vault exit"], 0, 2455, 2475, 7398, 7420)[0],
        },
        "everlight": {
            "door_surface": pick_in_box(parsed["Door (Everlight Dig Site)"], 0, 3680, 3845, 3125, 3320)[0],
            "door_underwater": pick_in_box(parsed["Door (Everlight Dig Site)"], 1, 2300, 2372, 7480, 7620)[0],
        },
        "infernal": {
            "surface_lift": pick_in_box(parsed["Infernal Source Dig Site"], 0, 3250, 3315, 3480, 3530)[0],
            "cellar_lift": cellar_lift,
            "secret_passage": pick_in_box(parsed["Secret passage"], 0, 2560, 2623, 7296, 7359)[0],
            "disorder_exit": disorder_to_cellar,
            "disorder_portal": pick_in_box(parsed["Portal (Dungeon of Disorder)"], 0, 2624, 2687, 7296, 7359)[0],
            "vestibule_exit": pick_in_box(parsed["Portal chamber (scenery)"], 3, 2560, 2687, 7360, 7487)[0],
            "vest_to_harr": (
                pick_in_box(parsed["Leo portal"], 3)
                + pick_in_box(parsed["Cancer portal"], 3)
                + pick_in_box(parsed["Taurus portal"], 3)
                + pick_in_box(parsed["Pisces portal"], 3)
            ),
            "harr_to_vest": (
                pick_in_box(parsed["Leo portal"], 2)
                + pick_in_box(parsed["Cancer portal"], 2)
                + pick_in_box(parsed["Taurus portal"], 2)
                + pick_in_box(parsed["Pisces portal"], 2)
            ),
            "vest_to_dagon": pick_in_box(parsed["Sagittarius portal"], 3) + pick_in_box(parsed["Aquarius portal"], 3),
            "dagon_to_vest": pick_in_box(parsed["Sagittarius portal"], 1) + pick_in_box(parsed["Aquarius portal"], 1),
            "harr_to_dagon": pick_in_box(parsed["Capricorn portal"], 2)[0],
            "dagon_to_harr": pick_in_box(parsed["Capricorn portal"], 1)[0],
        },
        "stormguard": {
            "portal_surface": pick_in_box(parsed["Stormguard portal"], 0, 2655, 2705, 3380, 3425)[0],
            "portal_citadel": pick_in_box(parsed["Stormguard portal"], 1, 2440, 2470, 7150, 7180)[0],
            "grav_core": pick_in_box(parsed["Gravitational core"], 1, 2390, 2430, 7135, 7170)[0],
            "howl_exit": pick_in_box(parsed["Stormguard Citadel - Howl's workshop excavation site"], 3, 2380, 2435, 7130, 7180)[0],
        },
        "warforge": {
            "surface_lift": pick_in_box(parsed["Warforge Dig Site"], 0, 2390, 2440, 2805, 2860)[0],
            "crucible_lift": crucible_lift,
            "tunnels_in": pick_in_box(parsed["Tunnels entrance"], 0, 2368, 2431, 7296, 7359)[0],
            "tunnels_out": pick_in_box(parsed["Tunnels exit"], 0, 2240, 2367, 7296, 7423)[0],
            "forge_doors_out": forge_doors_out,
            "forge_doors_in": forge_doors_in,
        },
        "orthen": {
            "surface_teles": pick_in_box(parsed["Orthen teleportation device"], 0, 3648, 4224, 4000, 4544),
            "varanus_door": orthen_doors["varanus_door"],
            "outpost_door": orthen_doors["outpost_door"],
            "moksha_stairs": pick_in_box(parsed["Stairs down (Moksha ritual site)"], 0, 3900, 4050, 4050, 4200)[0],
            "xolo_door": pick_in_box(parsed["Door (Xolo City)"], 0, 4080, 4200, 4020, 4150)[0],
            "varanus_exit": pick_in_box(parsed["Stairs out"], 2, 1086, 1154, 62, 194)[0],
            "outpost_exit": pick_in_box(parsed["Stairs out"], 0, 1214, 1282, 62, 130)[0],
            "moksha_exits": [orthen_doors["moksha_tele"]] + pick_in_box(parsed["Stairs out"], 1, 1086, 1154, 190, 258),
            "xolo_exit": pick_in_box(parsed["Stairs out"], 0, 1214, 1282, 190, 258)[0],
            "nodon_in": nodon_in,
            "nodon_out": nodon_out,
            "rex_in": (0, 4050, 4286),
            "rex_out": (0, 3904, 9855),
        },
        "senntisten": {
            "ancient_door": pick_in_box(parsed["Ancient door (Senntisten)"], 0, 3315, 3395, 3415, 3470)[0],
            "colosseum_in": colosseum_gateway,
            "colosseum_out": pick_in_box(parsed["Gate (Senntisten)"], 0, 320, 384, 128, 192)[0],
        },
        "daemonheim": {
            "stairs_up": pick_in_box(parsed["Staircase (Daemonheim)"], 0, 3390, 3500, 3675, 3775),
            "stairs_down": pick_in_box(parsed["Staircase (Daemonheim)"], 1, 3390, 3500, 3675, 3775),
            "depths_in": pick_in_box(parsed["Imposing door"], 0, 3440, 3480, 3735, 3770)[0],
            "depths_out": pick_in_box(parsed["Imposing door"], 1, 2195, 2225, 9215, 9265),
            "depths_2_down": pick_in_box(parsed["Staircase (Depths excavation site)"], 2, 2174, 2242, 9214, 9282)[0],
        },
        "moonrise": {
            "temple_in": pick_in_box(parsed["Temple doors"], 0, 4350, 4490, 3390, 3505)[0],
            "temple_out": pick_in_box(parsed["Temple doors"], 1, 3710, 3778, 7998, 8066)[0],
        },
    }


def lua_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def format_coord_list(coords: list[tuple[int, int, int]]) -> str:
    parts = [f"{{{l},{x},{z}}}" for (l, x, z) in coords]
    return "{ " + ", ".join(parts) + " }"


DIG_SITES_SPEC: dict[str, dict] = {
    "Kharid-et": {
        "name": "Kharid-et",
        "arrival": (0, 3345, 3194),
        "mapDynId": 0,
        "travelItems": ["pontifex"],
        "zones": [
            {"level": 0, "minX": 3330, "maxX": 3395, "minZ": 3160, "maxZ": 3220, "sub": "exterior"},
            {"level": 0, "minX": 2414, "maxX": 2522, "minZ": 7550, "maxZ": 7642, "sub": "barracks"},
            {"level": 0, "minX": 2432, "maxX": 2446, "minZ": 7368, "maxZ": 7394, "sub": "solitary"},
            {"level": 0, "minX": 2432, "maxX": 2453, "minZ": 7395, "maxZ": 7425, "sub": "solitary"},
            {"level": 0, "minX": 2448, "maxX": 2496, "minZ": 7358, "maxZ": 7425, "sub": "vault"},
            {"level": 0, "minX": 2235, "maxX": 2285, "minZ": 7560, "maxZ": 7620, "sub": "carcerem"},
            {"level": 0, "minX": 2620, "maxX": 2692, "minZ": 7548, "maxZ": 7620, "sub": "praetorium"},
        ],
    },
    "Everlight": {
        "name": "Everlight",
        "arrival": (0, 3697, 3207),
        "mapDynId": 1,
        "travelItems": [],
        "zones": [
            {"level": 0, "minX": 3680, "maxX": 3845, "minZ": 3125, "maxZ": 3320, "sub": "surface"},
            {"level": None, "minX": 2300, "maxX": 2372, "minZ": 7420, "maxZ": 7620, "sub": "underwater"},
        ],
    },
    "Infernal Source": {
        "name": "Infernal Source",
        "arrival": (0, 3271, 3505),
        "mapDynId": 2,
        "travelItems": [],
        "zones": [
            {"level": 0, "minX": 3250, "maxX": 3315, "minZ": 3480, "maxZ": 3530, "sub": "surface"},
            {"level": 0, "minX": 2558, "maxX": 2623, "minZ": 7294, "maxZ": 7360, "sub": "cellar"},
            {"level": 0, "minX": 2624, "maxX": 2690, "minZ": 7294, "maxZ": 7360, "sub": "disorder"},
            {"level": 3, "minX": 2558, "maxX": 2690, "minZ": 7358, "maxZ": 7490, "sub": "vestibule"},
            {"level": 2, "minX": 2558, "maxX": 2690, "minZ": 7358, "maxZ": 7490, "sub": "harrowing"},
            {"level": 1, "minX": 2558, "maxX": 2690, "minZ": 7358, "maxZ": 7490, "sub": "dagon"},
        ],
    },
    "Stormguard Citadel": {
        "name": "Stormguard Citadel",
        "arrival": (0, 2680, 3403),
        "mapDynId": 3,
        "travelItems": [],
        "zones": [
            {"level": 0, "minX": 2655, "maxX": 2705, "minZ": 3380, "maxZ": 3425, "sub": "surface"},
            {"level": 1, "minX": 2300, "maxX": 2564, "minZ": 7036, "maxZ": 7300, "sub": "citadel"},
            {"level": 3, "minX": 2300, "maxX": 2564, "minZ": 7036, "maxZ": 7300, "sub": "howl"},
        ],
    },
    "Warforge": {
        "name": "Warforge",
        "arrival": (0, 2409, 2825),
        "mapDynId": 4,
        "travelItems": [],
        "zones": [
            {"level": 0, "minX": 2375, "maxX": 2440, "minZ": 2805, "maxZ": 2860, "sub": "surface"},
            {"level": 0, "minX": 2368, "maxX": 2431, "minZ": 7294, "maxZ": 7359, "sub": "sanctum"},
            {"level": 0, "minX": 2274, "maxX": 2306, "minZ": 7351, "maxZ": 7371, "sub": "forge"},
            {"level": 0, "minX": 2238, "maxX": 2367, "minZ": 7294, "maxZ": 7425, "sub": "tunnels"},
        ],
    },
    "Orthen": {
        "name": "Orthen",
        "arrival": (0, 3921, 4259),
        "mapDynId": 5,
        "travelItems": [],
        "zones": [
            {"level": 1, "minX": 5500, "maxX": 5570, "minZ": 2810, "maxZ": 2880, "sub": "nodon"},
            {"level": None, "minX": 5376, "maxX": 5695, "minZ": 2112, "maxZ": 2943, "sub": "anachronia_alt"},
            {"level": None, "minX": 3648, "maxX": 4224, "minZ": 4000, "maxZ": 4544, "sub": "anachronia"},
            {"level": 0, "minX": 1214, "maxX": 1282, "minZ": 62, "maxZ": 130, "sub": "outpost"},
            {"level": 0, "minX": 1214, "maxX": 1282, "minZ": 190, "maxZ": 258, "sub": "xolo"},
            {"level": 1, "minX": 1086, "maxX": 1154, "minZ": 190, "maxZ": 258, "sub": "moksha"},
            {"level": 2, "minX": 1086, "maxX": 1154, "minZ": 62, "maxZ": 194, "sub": "varanus"},
            {"level": None, "minX": 3840, "maxX": 3968, "minZ": 9792, "maxZ": 9920, "sub": "rex_lair"},
        ],
    },
    "Senntisten": {
        "name": "Senntisten",
        "arrival": (0, 1784, 1296),
        "mapDynId": 6,
        "travelItems": ["pontifex", "dig site pendant"],
        "zones": [
            {"level": 0, "minX": 3315, "maxX": 3395, "minZ": 3415, "maxZ": 3470, "sub": "surface_gate"},
            {"level": None, "minX": 1600, "maxX": 2048, "minZ": 1024, "maxZ": 1408, "sub": "city"},
            {"level": None, "minX": 320, "maxX": 384, "minZ": 128, "maxZ": 192, "sub": "colosseum"},
        ],
    },
    "Daemonheim": {
        "name": "Daemonheim",
        "arrival": (0, 3428, 3699),
        "mapDynId": 7,
        "travelItems": ["ring of kinship"],
        "zones": [
            {"level": 0, "minX": 3390, "maxX": 3500, "minZ": 3640, "maxZ": 3775, "sub": "castle_0"},
            {"level": 1, "minX": 3390, "maxX": 3500, "minZ": 3675, "maxZ": 3775, "sub": "castle_1"},
            {"level": 1, "minX": 2174, "maxX": 2242, "minZ": 9214, "maxZ": 9282, "sub": "depths"},
            {"level": 2, "minX": 2174, "maxX": 2242, "minZ": 9214, "maxZ": 9282, "sub": "depths_2"},
        ],
    },
    "Moonrise": {
        "name": "Moonrise",
        "arrival": (0, 4418, 3443),
        "mapDynId": 8,
        "travelItems": [],
        "zones": [
            {"level": 0, "minX": 4305, "maxX": 4490, "minZ": 3390, "maxZ": 3505, "sub": "periphery"},
            {"level": 1, "minX": 3710, "maxX": 3778, "minZ": 7998, "maxZ": 8066, "sub": "depths"},
        ],
    },
    "Archaeology Campus": {
        "name": "Archaeology Campus",
        "arrival": (0, 3336, 3378),
        "mapDynId": None,
        "travelItems": ["dig site pendant"],
        "zones": [
            {"level": None, "minX": 3305, "maxX": 3415, "minZ": 3345, "maxZ": 3425, "sub": "campus"},
        ],
    },
}


def py_find_zone_at(coord: tuple[int, int, int]) -> tuple[str | None, str | None]:
    pl, px, pz = coord
    for site_key, site in DIG_SITES_SPEC.items():
        for z in site["zones"]:
            if (z["level"] is None or z["level"] == pl) and z["minX"] <= px <= z["maxX"] and z["minZ"] <= pz <= z["maxZ"]:
                return site_key, z["sub"]
    return None, None


def mk_tr(
    coord_or_list: tuple[int, int, int] | list[tuple[int, int, int]],
    label: str,
    cfg: str | None = None,
    obj_ids: list[int] | None = None,
    alt: tuple[tuple[int, int, int], int, str, str | None] | None = None,
    dlg: list[str] | None = None,
    via: str | None = None,
) -> dict:
    pts = [coord_or_list] if isinstance(coord_or_list, tuple) else list(coord_or_list)
    return {
        "pts": pts,
        "label": label,
        "cfg": cfg,
        "obj_ids": obj_ids,
        "alt": alt,
        "dlg": dlg,
        "via": via,
    }


def fmt_tr_spec(tr: dict) -> str:
    pts = tr["pts"]
    l0, x0, z0 = pts[0]
    fields = [f"level = {l0}", f"x = {x0}", f"z = {z0}", f'label = "{lua_escape(tr["label"])}"']
    if len(pts) > 1:
        fields.append(f"candidates = {format_coord_list(pts)}")
    if tr["cfg"]:
        fields.append(f'cfg = "{lua_escape(tr["cfg"])}"')
    if tr["obj_ids"]:
        fields.append("objIds = { " + ", ".join(str(i) for i in tr["obj_ids"]) + " }")
    if tr["dlg"]:
        fields.append("dlg = { " + ", ".join(f'"{lua_escape(d)}"' for d in tr["dlg"]) + " }")
    if tr["alt"]:
        (al, ax, az), rad, alabel, acfg = tr["alt"]
        af = [f"level = {al}", f"x = {ax}", f"z = {az}", f"radius = {rad}", f'label = "{lua_escape(alabel)}"']
        if acfg:
            af.append(f'cfg = "{lua_escape(acfg)}"')
        fields.append("alt = { " + ", ".join(af) + " }")
    return "{ " + ", ".join(fields) + " }"


def build_transitions_spec(td: dict) -> dict[str, dict[str, dict[str, dict]]]:
    kh = td["kharidet"]
    ev = td["everlight"]
    inf = td["infernal"]
    sg = td["stormguard"]
    wf = td["warforge"]
    ort = td["orthen"]
    sn = td["senntisten"]
    dm = td["daemonheim"]
    mr = td["moonrise"]

    return {
        "Kharid-et": {
            "exterior": {
                "barracks": mk_tr(kh["fort_entrance"], "Enter Kharid-et Fortress", "arch_kharidet_entrance", [116925, 116926], dlg=["main fortress", "fortress", "barracks"], via="barracks"),
                "carcerem": mk_tr(kh["fort_entrance"], "Enter Kharid-et Fortress -> Prison Block", "arch_kharidet_entrance", [116925, 116926], dlg=["prison block", "carcerem", "prison", "main fortress", "fortress"], via="carcerem"),
                "solitary": mk_tr(kh["fort_entrance"], "Enter Kharid-et Fortress -> Prison Block", "arch_kharidet_entrance", [116925, 116926], dlg=["prison block", "carcerem", "prison", "main fortress", "fortress"], via="carcerem"),
                "praetorium": mk_tr(kh["fort_entrance"], "Enter Kharid-et Fortress -> Praetorium", "arch_kharidet_entrance", [116925, 116926], dlg=["praetorium", "war table", "main fortress", "fortress", "barracks"], via="barracks"),
                "vault": mk_tr(kh["fort_entrance"], "Enter Kharid-et Fortress -> Vault", "arch_kharidet_entrance", [116925, 116926], dlg=["vault of shadows", "vault", "main fortress", "fortress", "barracks"], via="barracks"),
            },
            "barracks": {
                "exterior": mk_tr(kh["fort_exit"], "Exit Kharid-et Fortress (north tunnel)", "arch_kharidet", [116927], via="exterior"),
                "carcerem": mk_tr(kh["prison_door"], "Enter Prison Block door", "arch_kharidet_doorway_large", [116972, 116974], dlg=["enter", "prison", "yes"], via="carcerem"),
                "solitary": mk_tr(kh["prison_door"], "Enter Prison Block door -> Solitary", "arch_kharidet_doorway_large", [116972, 116974], dlg=["enter", "prison", "yes"], via="carcerem"),
                "praetorium": mk_tr(kh["praetorium_in"], "Enter Praetorium War Table", "arch_kharidet_praetorium_entrance", [116937, 116938], dlg=["praetorium", "enter", "yes"], via="praetorium"),
                "vault": mk_tr(kh["vault_in_buttons"], "Press Vault button to enter Vault", "button", [116941, 116944], dlg=["yes", "enter", "vault"], via="vault"),
            },
            "carcerem": {
                "exterior": mk_tr(kh["prison_exit"], "Exit Prison Block (north-west door) to Barracks", "door", via="barracks"),
                "barracks": mk_tr(kh["prison_exit"], "Exit Prison Block (north-west door) to Barracks", "door", via="barracks"),
                "praetorium": mk_tr(kh["prison_exit"], "Exit Prison Block (north-west door) -> War Table", "door", via="barracks"),
                "vault": mk_tr(kh["prison_exit"], "Exit Prison Block (north-west door) to Barracks", "door", via="barracks"),
            },
            "solitary": {
                "exterior": mk_tr(kh["solitary_exit"], "Exit Solitary Confinement (west door) to Prison Block", "door", via="carcerem"),
                "barracks": mk_tr(kh["solitary_exit"], "Exit Solitary Confinement (west door) to Prison Block", "door", via="carcerem"),
                "carcerem": mk_tr(kh["solitary_exit"], "Exit Solitary Confinement (west door) to Prison Block", "door", via="carcerem"),
                "praetorium": mk_tr(kh["solitary_exit"], "Exit Solitary Confinement (west door) to Prison Block", "door", via="carcerem"),
                "vault": mk_tr(kh["solitary_exit"], "Exit Solitary Confinement (west door) to Prison Block", "door", via="carcerem"),
            },
            "praetorium": {
                "exterior": mk_tr(kh["praetorium_out"], "Exit Praetorium War Table", "arch_kharidet_praetorium_exit", [116939], via="barracks"),
                "barracks": mk_tr(kh["praetorium_out"], "Exit Praetorium War Table", "arch_kharidet_praetorium_exit", [116939], via="barracks"),
                "carcerem": mk_tr(kh["praetorium_out"], "Exit Praetorium War Table", "arch_kharidet_praetorium_exit", [116939], via="barracks"),
                "solitary": mk_tr(kh["praetorium_out"], "Exit Praetorium War Table", "arch_kharidet_praetorium_exit", [116939], via="barracks"),
                "vault": mk_tr(kh["praetorium_out"], "Exit Praetorium War Table", "arch_kharidet_praetorium_exit", [116939], via="barracks"),
            },
            "vault": {
                "exterior": mk_tr(kh["vault_out_chapel"], "Use Vault exit to Fortress", "arch_kharidet_vault_exit", [116960, 116963], via="barracks"),
                "barracks": mk_tr(kh["vault_out_chapel"], "Use Vault exit to Fortress", "arch_kharidet_vault_exit", [116960, 116963], via="barracks"),
                "carcerem": mk_tr(kh["vault_out_prison"], "Use Ice Vault exit to Prison Block", "arch_kharidet_vault_exit_ice", [116961], via="carcerem"),
                "solitary": mk_tr(kh["vault_out_prison"], "Use Ice Vault exit to Prison Block", "arch_kharidet_vault_exit_ice", [116961], via="carcerem"),
                "praetorium": mk_tr(kh["vault_out_praetorium"], "Use Shadow Vault exit to Praetorium", "arch_kharidet_vault_exit_shadow", [116962], via="praetorium"),
            },
        },
        "Everlight": {
            "surface": {
                "underwater": mk_tr(ev["door_surface"], "Enter Acropolis underground door", None, [116492, 116494], dlg=["underwater", "cave", "descend", "enter", "yes"], via="underwater"),
            },
            "underwater": {
                "surface": mk_tr(ev["door_underwater"], "Exit door to Everlight surface", None, [116499], dlg=["surface", "ascend", "exit", "leave", "yes"], via="surface"),
            },
        },
        "Infernal Source": {
            "surface": {
                "cellar": mk_tr(inf["surface_lift"], "Descend Infernal Source lift -> Star Lodge Cellar", "lift", dlg=["star lodge", "cellar"], via="cellar"),
                "disorder": mk_tr(inf["surface_lift"], "Descend Infernal Source lift -> Dungeon of Disorder", "lift", dlg=["dungeon of disorder", "disorder", "star lodge", "cellar"], via="disorder"),
                "vestibule": mk_tr(inf["surface_lift"], "Descend Infernal Source lift -> Vestibule of Futility", "lift", dlg=["vestibule of futility", "vestibule", "the source", "dungeon of disorder", "disorder", "star lodge", "cellar"], via="vestibule"),
                "harrowing": mk_tr(inf["surface_lift"], "Descend Infernal Source lift -> The Harrowing", "lift", dlg=["the harrowing", "harrowing", "vestibule of futility", "vestibule", "dungeon of disorder", "disorder", "star lodge", "cellar"], via="harrowing"),
                "dagon": mk_tr(inf["surface_lift"], "Descend Infernal Source lift -> Dagon Overlook", "lift", dlg=["dagon overlook", "dagon", "the harrowing", "harrowing", "vestibule of futility", "vestibule", "dungeon of disorder", "disorder", "star lodge", "cellar"], via="dagon"),
            },
            "cellar": {
                "surface": mk_tr(inf["cellar_lift"], "Ascend Star Lodge lift to surface", "lift", dlg=["surface", "up", "exit", "yes"], via="surface"),
                "disorder": mk_tr(inf["secret_passage"], "Climb down Secret Passage behind hearth", "arch_infernalsource_cellar_fireplace", [116698, 116699], dlg=["yes", "enter", "climb"], via="disorder"),
                "vestibule": mk_tr(inf["secret_passage"], "Climb down Secret Passage behind hearth", "arch_infernalsource_cellar_fireplace", [116698, 116699], dlg=["yes", "enter", "climb"], via="disorder"),
                "harrowing": mk_tr(inf["secret_passage"], "Climb down Secret Passage behind hearth", "arch_infernalsource_cellar_fireplace", [116698, 116699], dlg=["yes", "enter", "climb"], via="disorder"),
                "dagon": mk_tr(inf["secret_passage"], "Climb down Secret Passage behind hearth", "arch_infernalsource_cellar_fireplace", [116698, 116699], dlg=["yes", "enter", "climb"], via="disorder"),
            },
            "disorder": {
                "surface": mk_tr(inf["disorder_exit"], "Climb up stairs to Star Lodge Cellar", via="cellar"),
                "cellar": mk_tr(inf["disorder_exit"], "Climb up stairs to Star Lodge Cellar", via="cellar"),
                "vestibule": mk_tr(inf["disorder_portal"], "Enter Dungeon of Disorder ritual portal", "portal", [116732, 116734, 116735], dlg=["vestibule", "enter", "yes"], via="vestibule"),
                "harrowing": mk_tr(inf["disorder_portal"], "Enter Dungeon of Disorder ritual portal", "portal", [116732, 116734, 116735], dlg=["harrowing", "vestibule", "enter", "yes"], via="vestibule"),
                "dagon": mk_tr(inf["disorder_portal"], "Enter Dungeon of Disorder ritual portal", "portal", [116732, 116734, 116735], dlg=["dagon", "vestibule", "enter", "yes"], via="vestibule"),
            },
            "vestibule": {
                "surface": mk_tr(inf["vestibule_exit"], "Leave via Portal Chamber", "arch_research_infernalsource_vestibule", [116787, 116788], dlg=["surface", "leave", "exit", "disorder", "yes"], via="disorder"),
                "cellar": mk_tr(inf["vestibule_exit"], "Leave via Portal Chamber", "arch_research_infernalsource_vestibule", [116787, 116788], dlg=["cellar", "disorder", "leave", "exit", "yes"], via="disorder"),
                "disorder": mk_tr(inf["vestibule_exit"], "Leave via Portal Chamber", "arch_research_infernalsource_vestibule", [116787, 116788], dlg=["disorder", "leave", "exit", "yes"], via="disorder"),
                "harrowing": mk_tr(inf["vest_to_harr"], "Enter red Dagon portal to The Harrowing", "arch_infernalsource_malebranche_portal", [116741, 116743, 116744, 116751], via="harrowing"),
                "dagon": mk_tr(inf["vest_to_dagon"], "Enter red Dagon portal to Dagon Overlook", "arch_infernalsource_malebranche_portal", [116748, 116750], via="dagon"),
            },
            "harrowing": {
                "dagon": mk_tr(inf["harr_to_dagon"], "Enter Capricorn portal to Dagon Overlook", "arch_infernalsource_malebranche_portal_10", [116749], via="dagon"),
                "vestibule": mk_tr(inf["harr_to_vest"], "Enter red Dagon portal up to Vestibule", "arch_infernalsource_malebranche_portal", [116741, 116743, 116744, 116751], via="vestibule"),
                "disorder": mk_tr(inf["harr_to_vest"], "Enter red Dagon portal up to Vestibule", "arch_infernalsource_malebranche_portal", [116741, 116743, 116744, 116751], via="vestibule"),
                "cellar": mk_tr(inf["harr_to_vest"], "Enter red Dagon portal up to Vestibule", "arch_infernalsource_malebranche_portal", [116741, 116743, 116744, 116751], via="vestibule"),
                "surface": mk_tr(inf["harr_to_vest"], "Enter red Dagon portal up to Vestibule", "arch_infernalsource_malebranche_portal", [116741, 116743, 116744, 116751], via="vestibule"),
            },
            "dagon": {
                "harrowing": mk_tr(inf["dagon_to_harr"], "Enter Capricorn portal up to The Harrowing", "arch_infernalsource_malebranche_portal_10", [116749], via="harrowing"),
                "vestibule": mk_tr(inf["dagon_to_vest"], "Enter red Dagon portal up to Vestibule", "arch_infernalsource_malebranche_portal", [116748, 116750], via="vestibule"),
                "disorder": mk_tr(inf["dagon_to_vest"], "Enter red Dagon portal up to Vestibule", "arch_infernalsource_malebranche_portal", [116748, 116750], via="vestibule"),
                "cellar": mk_tr(inf["dagon_to_vest"], "Enter red Dagon portal up to Vestibule", "arch_infernalsource_malebranche_portal", [116748, 116750], via="vestibule"),
                "surface": mk_tr(inf["dagon_to_vest"], "Enter red Dagon portal up to Vestibule", "arch_infernalsource_malebranche_portal", [116748, 116750], via="vestibule"),
            },
        },
        "Stormguard Citadel": {
            "surface": {
                "citadel": mk_tr(sg["portal_surface"], "Teleport via Stormguard portal", "arch_stormguard_entrance", [117129], dlg=["stormguard", "citadel", "keshik", "yes"], via="citadel"),
                "howl": mk_tr(sg["portal_surface"], "Teleport via Stormguard portal", "arch_stormguard_entrance", [117129], dlg=["howl", "workshop", "north-west", "northwest", "stormguard", "citadel", "yes"], via="citadel"),
            },
            "citadel": {
                "surface": mk_tr(sg["portal_citadel"], "Exit via Stormguard portal", "arch_stormguard_exit", [117130], dlg=["temple of ikov", "ikov", "camp", "surface", "exit", "leave", "yes"], via="surface"),
                "howl": mk_tr(sg["grav_core"], "Interact with Gravitational core -> Howl's Workshop", "gravitational", [117174, 117175], dlg=["howl's workshop", "howl", "workshop", "up", "enter", "yes"], via="howl"),
            },
            "howl": {
                "citadel": mk_tr(sg["howl_exit"], "Exit Howl's Workshop via Gravitational core", "gravitational", [117174, 117175], dlg=["research", "citadel", "down", "exit", "leave", "yes"], via="citadel"),
                "surface": mk_tr(sg["howl_exit"], "Exit Howl's Workshop via Gravitational core", "gravitational", [117174, 117175], dlg=["temple of ikov", "research", "citadel", "down", "exit", "leave", "yes"], via="citadel"),
            },
        },
        "Warforge": {
            "surface": {
                "sanctum": mk_tr(wf["surface_lift"], "Descend Warforge lift -> Crucible", "lift", dlg=["the crucible", "crucible", "bandos", "sanctum"], via="sanctum"),
                "tunnels": mk_tr(wf["surface_lift"], "Descend Warforge lift -> Goblin Tunnels", "lift", dlg=["goblin tunnels", "the tunnels", "tunnels"], via="tunnels"),
                "forge": mk_tr(wf["surface_lift"], "Descend Warforge lift -> Thalmund's Forge", "lift", dlg=["thalmund's forge", "the forge", "forge", "goblin tunnels", "the tunnels", "tunnels"], via="forge"),
            },
            "sanctum": {
                "surface": mk_tr(wf["crucible_lift"], "Ascend Warforge lift to surface", "lift", dlg=["surface", "up", "exit", "yes"], via="surface"),
                "tunnels": mk_tr(wf["tunnels_in"], "Enter Goblin Tunnels entrance", "arch_warforge_tunnels_entrance", [117248], via="tunnels"),
                "forge": mk_tr(wf["tunnels_in"], "Enter Goblin Tunnels entrance -> Forge", "arch_warforge_tunnels_entrance", [117248], via="tunnels"),
            },
            "tunnels": {
                "sanctum": mk_tr(wf["tunnels_out"], "Exit Goblin Tunnels to Crucible", "arch_warforge_tunnels_exit", [117249], via="sanctum"),
                "surface": mk_tr(wf["tunnels_out"], "Exit Goblin Tunnels to Crucible", "arch_warforge_tunnels_exit", [117249], via="sanctum"),
                "forge": mk_tr(wf["forge_doors_out"], "Enter Thalmund's Forge doors", "door", [117252, 117254], dlg=["enter", "forge", "yes"], via="forge"),
            },
            "forge": {
                "tunnels": mk_tr(wf["forge_doors_in"], "Exit Thalmund's Forge doors to Tunnels", "door", [117252, 117254], via="tunnels"),
                "sanctum": mk_tr(wf["forge_doors_in"], "Exit Thalmund's Forge doors -> Crucible", "door", [117252, 117254], via="tunnels"),
                "surface": mk_tr(wf["forge_doors_in"], "Exit Thalmund's Forge doors -> Lift", "door", [117252, 117254], via="tunnels"),
            },
        },
        "Orthen": {
            "anachronia": {
                "varanus": mk_tr(ort["surface_teles"], "Use Orthen teleportation device -> Crypt of Varanus", "teleportation device", [119029, 119030, 119031, 119034], (ort["varanus_door"], 48, "Enter Crypt of Varanus door", "door"), dlg=["crypt of varanus", "varanus", "crypt"], via="varanus"),
                "outpost": mk_tr(ort["surface_teles"], "Use Orthen teleportation device -> Observation Outpost", "teleportation device", [119029, 119030, 119031, 119034], (ort["outpost_door"], 48, "Enter Observation Outpost door", "door"), dlg=["observation outpost", "outpost"], via="outpost"),
                "moksha": mk_tr(ort["surface_teles"], "Use Orthen teleportation device -> Moksha Ritual Site", "teleportation device", [119029, 119030, 119031, 119034], (ort["moksha_stairs"], 48, "Enter Moksha Ritual Site stairs", "arch_orthen_moksha_surface_entrance"), dlg=["moksha ritual site", "moksha", "ritual site"], via="moksha"),
                "xolo": mk_tr(ort["surface_teles"], "Use Orthen teleportation device -> Xolo City", "teleportation device", [119029, 119030, 119031, 119034], (ort["xolo_door"], 48, "Enter Xolo City door", "arch_orthen_xolo_city_entrance"), dlg=["xolo city", "xolo"], via="xolo"),
                "nodon": mk_tr(ort["nodon_in"], "Enter Nodon Hibernatorium ruins", "door", via="nodon"),
                "rex_lair": mk_tr(ort["rex_in"], "Enter Rex Matriarch lair", "entrance", via="rex_lair"),
            },
            "varanus": {
                "anachronia": mk_tr(ort["varanus_exit"], "Exit Crypt of Varanus stairs", "arch_orthen_crypt_of_varanus_exit", [119043], via="anachronia"),
                "outpost": mk_tr(ort["varanus_exit"], "Exit Crypt of Varanus -> Orthen teleportation device", "arch_orthen_crypt_of_varanus_exit", [119043], via="anachronia"),
                "moksha": mk_tr(ort["varanus_exit"], "Exit Crypt of Varanus -> Orthen teleportation device", "arch_orthen_crypt_of_varanus_exit", [119043], via="anachronia"),
                "xolo": mk_tr(ort["varanus_exit"], "Exit Crypt of Varanus -> Orthen teleportation device", "arch_orthen_crypt_of_varanus_exit", [119043], via="anachronia"),
                "nodon": mk_tr(ort["varanus_exit"], "Exit Crypt of Varanus -> Anachronia", "arch_orthen_crypt_of_varanus_exit", [119043], via="anachronia"),
                "rex_lair": mk_tr(ort["varanus_exit"], "Exit Crypt of Varanus -> Anachronia", "arch_orthen_crypt_of_varanus_exit", [119043], via="anachronia"),
            },
            "outpost": {
                "anachronia": mk_tr(ort["outpost_exit"], "Exit Observation Outpost stairs", "arch_orthen_observation_outpost_exit", [119050], via="anachronia"),
                "varanus": mk_tr(ort["outpost_exit"], "Exit Observation Outpost -> Orthen teleportation device", "arch_orthen_observation_outpost_exit", [119050], via="anachronia"),
                "moksha": mk_tr(ort["outpost_exit"], "Exit Observation Outpost -> Orthen teleportation device", "arch_orthen_observation_outpost_exit", [119050], via="anachronia"),
                "xolo": mk_tr(ort["outpost_exit"], "Exit Observation Outpost -> Orthen teleportation device", "arch_orthen_observation_outpost_exit", [119050], via="anachronia"),
                "nodon": mk_tr(ort["outpost_exit"], "Exit Observation Outpost -> Anachronia", "arch_orthen_observation_outpost_exit", [119050], via="anachronia"),
                "rex_lair": mk_tr(ort["outpost_exit"], "Exit Observation Outpost -> Anachronia", "arch_orthen_observation_outpost_exit", [119050], via="anachronia"),
            },
            "moksha": {
                "anachronia": mk_tr(ort["moksha_exits"], "Use Orthen teleportation device or Stairs out", "arch_orthen_moksha", [119029, 119034, 119065], dlg=["base camp", "anachronia"], via="anachronia"),
                "varanus": mk_tr(ort["moksha_exits"], "Use Orthen teleportation device -> Crypt of Varanus", "teleportation device", [119029, 119034, 119065], dlg=["crypt of varanus", "varanus", "crypt"], via="varanus"),
                "outpost": mk_tr(ort["moksha_exits"], "Use Orthen teleportation device -> Observation Outpost", "teleportation device", [119029, 119034, 119065], dlg=["observation outpost", "outpost"], via="outpost"),
                "xolo": mk_tr(ort["moksha_exits"], "Use Orthen teleportation device -> Xolo City", "teleportation device", [119029, 119034, 119065], dlg=["xolo city", "xolo"], via="xolo"),
                "nodon": mk_tr(ort["moksha_exits"], "Use Orthen teleportation device -> Base Camp", "teleportation device", [119029, 119034, 119065], dlg=["base camp", "anachronia"], via="anachronia"),
                "rex_lair": mk_tr(ort["moksha_exits"], "Use Orthen teleportation device -> Base Camp", "teleportation device", [119029, 119034, 119065], dlg=["base camp", "anachronia"], via="anachronia"),
            },
            "xolo": {
                "anachronia": mk_tr(ort["xolo_exit"], "Exit Xolo City stairs", "arch_orthen_xolo_city_exit", [119067], via="anachronia"),
                "varanus": mk_tr(ort["xolo_exit"], "Exit Xolo City stairs", "arch_orthen_xolo_city_exit", [119067], via="anachronia"),
                "outpost": mk_tr(ort["xolo_exit"], "Exit Xolo City stairs", "arch_orthen_xolo_city_exit", [119067], via="anachronia"),
                "moksha": mk_tr(ort["xolo_exit"], "Exit Xolo City stairs", "arch_orthen_xolo_city_exit", [119067], via="anachronia"),
                "nodon": mk_tr(ort["xolo_exit"], "Exit Xolo City stairs", "arch_orthen_xolo_city_exit", [119067], via="anachronia"),
                "rex_lair": mk_tr(ort["xolo_exit"], "Exit Xolo City stairs", "arch_orthen_xolo_city_exit", [119067], via="anachronia"),
            },
            "nodon": {
                "anachronia": mk_tr(ort["nodon_out"], "Exit Nodon Hibernatorium", "exit", via="anachronia"),
                "varanus": mk_tr(ort["nodon_out"], "Exit Nodon Hibernatorium -> Anachronia", "exit", via="anachronia"),
                "outpost": mk_tr(ort["nodon_out"], "Exit Nodon Hibernatorium -> Anachronia", "exit", via="anachronia"),
                "moksha": mk_tr(ort["nodon_out"], "Exit Nodon Hibernatorium -> Anachronia", "exit", via="anachronia"),
                "xolo": mk_tr(ort["nodon_out"], "Exit Nodon Hibernatorium -> Anachronia", "exit", via="anachronia"),
                "rex_lair": mk_tr(ort["nodon_out"], "Exit Nodon Hibernatorium -> Anachronia", "exit", via="anachronia"),
            },
            "rex_lair": {
                "anachronia": mk_tr(ort["rex_out"], "Exit Rex Matriarch lair", "exit", via="anachronia"),
                "varanus": mk_tr(ort["rex_out"], "Exit Rex Matriarch lair -> Anachronia", "exit", via="anachronia"),
                "outpost": mk_tr(ort["rex_out"], "Exit Rex Matriarch lair -> Anachronia", "exit", via="anachronia"),
                "moksha": mk_tr(ort["rex_out"], "Exit Rex Matriarch lair -> Anachronia", "exit", via="anachronia"),
                "xolo": mk_tr(ort["rex_out"], "Exit Rex Matriarch lair -> Anachronia", "exit", via="anachronia"),
                "nodon": mk_tr(ort["rex_out"], "Exit Rex Matriarch lair -> Anachronia", "exit", via="anachronia"),
            },
        },
        "Senntisten": {
            "surface_gate": {
                "city": mk_tr(sn["ancient_door"], "Enter Senntisten Ancient Door", "egwd_surface_entrance_door", [119483], dlg=["yes"], via="city"),
                "colosseum": mk_tr(sn["ancient_door"], "Enter Senntisten Ancient Door", "egwd_surface_entrance_door", [119483], dlg=["yes"], via="city"),
            },
            "city": {
                "colosseum": mk_tr(sn["colosseum_in"], "Enter Colosseum gateway (Non-combat)", "egwd_colosseum_entrance", [120046], dlg=["non-combat", "non combat", "yes"], via="colosseum"),
            },
            "colosseum": {
                "city": mk_tr(sn["colosseum_out"], "Exit Colosseum gate to Senntisten", "egwd_colosseum_exit", [120047], via="city"),
            },
        },
        "Daemonheim": {
            "castle_0": {
                "castle_1": mk_tr(dm["stairs_up"], "Climb up Daemonheim Castle staircase", "rand_dragonkin_ruin_staircase", [48611, 48612], via="castle_1"),
                "depths": mk_tr(dm["depths_in"], "Enter Imposing Door to Daemonheim Depths", "arch_research_daemonheim_depths_door", [130289, 130291], dlg=["enter", "depths", "yes"], via="depths"),
            },
            "castle_1": {
                "castle_0": mk_tr(dm["stairs_down"], "Climb down Daemonheim Castle staircase", "rand_dragonkin_ruin_staircase", [50567, 50568], via="castle_0"),
                "depths": mk_tr(dm["stairs_down"], "Climb down Daemonheim Castle staircase -> Imposing Door", "rand_dragonkin_ruin_staircase", [50567, 50568], via="castle_0"),
            },
            "depths": {
                "castle_0": mk_tr(dm["depths_out"], "Exit Daemonheim Depths via Imposing Door", "arch_research_daemonheim_depths_door_to_castle", [130292], via="castle_0"),
                "castle_1": mk_tr(dm["depths_out"], "Exit Daemonheim Depths via Imposing Door", "arch_research_daemonheim_depths_door_to_castle", [130292], via="castle_0"),
            },
            "depths_2": {
                "depths": mk_tr(dm["depths_2_down"], "Climb down Depths staircase", "arch_daemonheim_steps_upstairs", [130301], via="depths"),
                "castle_0": mk_tr(dm["depths_2_down"], "Climb down Depths staircase", "arch_daemonheim_steps_upstairs", [130301], via="depths"),
                "castle_1": mk_tr(dm["depths_2_down"], "Climb down Depths staircase", "arch_daemonheim_steps_upstairs", [130301], via="depths"),
            },
        },
        "Moonrise": {
            "periphery": {
                "depths": mk_tr(mr["temple_in"], "Enter Moonrise Temple doors", "arch_moonrise_temple_entrance", [137388], dlg=["enter", "depths", "temple", "yes"], via="depths"),
            },
            "depths": {
                "periphery": mk_tr(mr["temple_out"], "Exit Moonrise Temple doors", "arch_moonrise_temple_exit", [137389], via="periphery"),
            },
        },
    }


def validate_navigation_graph(
    trans_spec: dict[str, dict[str, dict[str, dict]]],
    hotspots_map: dict[str, tuple[str, str, list[tuple[int, int, int]]]],
    caches_map: dict[str, list[tuple[int, int, int]]],
) -> None:
    """Strict build-time verifier ensuring zero wrong-plane doors, unzoned digsite spots, or broken multi-hop paths."""
    errors: list[str] = []

    # 1. Verify every Dig Site arrival coordinate resolves to that site's arrival sub-zone.
    arrival_subs: dict[str, str] = {}
    for site_key, sdef in DIG_SITES_SPEC.items():
        s_found, sub_found = py_find_zone_at(sdef["arrival"])
        if s_found != site_key or not sub_found:
            errors.append(f"Arrival coord {sdef['arrival']} for {site_key} resolved to {(s_found, sub_found)}")
        else:
            arrival_subs[site_key] = sub_found

    # 2. Verify EVERY transition coordinate (primary, candidates, and alt) sits strictly inside (site_key, from_sub)!
    for site_key, site_map in trans_spec.items():
        for from_sub, targets in site_map.items():
            for to_sub, tr in targets.items():
                for pt in tr["pts"]:
                    s_found, sub_found = py_find_zone_at(pt)
                    if (s_found, sub_found) != (site_key, from_sub):
                        errors.append(
                            f"Transition {site_key}.{from_sub}->{to_sub} point {pt} is in {(s_found, sub_found)}, expected {(site_key, from_sub)}"
                        )
                if tr["alt"]:
                    alt_pt = tr["alt"][0]
                    s_found, sub_found = py_find_zone_at(alt_pt)
                    if (s_found, sub_found) != (site_key, from_sub):
                        errors.append(
                            f"Transition {site_key}.{from_sub}->{to_sub} alt {alt_pt} is in {(s_found, sub_found)}, expected {(site_key, from_sub)}"
                        )

    # 3. Collect all active sub-zones containing hotspots or caches in each canonical Dig Site.
    active_subs: dict[str, set[str]] = {sk: {sub} for sk, sub in arrival_subs.items() if sk != "Archaeology Campus"}
    for key, (raw_name, site, coords) in hotspots_map.items():
        if site in DIG_SITES_SPEC and site != "Archaeology Campus":
            for c in coords:
                s_found, sub_found = py_find_zone_at(c)
                if s_found == site and sub_found:
                    active_subs[site].add(sub_found)
                elif site != "Senntisten" or c != (0, 735, 375):  # Quest-only Forum entrance instance
                    errors.append(f"Hotspot '{raw_name}' ({site}) coord {c} fell outside site zones: {(s_found, sub_found)}")

    for mat_name, coords in caches_map.items():
        for c in coords:
            s_found, sub_found = py_find_zone_at(c)
            if s_found and s_found != "Archaeology Campus" and sub_found:
                active_subs[s_found].add(sub_found)

    # 4. Verify cycle-free multi-hop progression for EVERY (from_sub, to_sub) pair across all active sub-zones!
    for site_key, subs in active_subs.items():
        site_map = trans_spec.get(site_key, {})
        all_from_subs = set(subs) | set(site_map.keys())
        for start_sub in sorted(all_from_subs):
            for goal_sub in sorted(subs):
                if start_sub == goal_sub:
                    continue
                cur = start_sub
                visited = {cur}
                steps = 0
                while cur != goal_sub:
                    tr = site_map.get(cur, {}).get(goal_sub)
                    if not tr:
                        errors.append(f"Missing transition {site_key}: {start_sub} -> {goal_sub} (stalled at '{cur}')")
                        break
                    nxt = tr["via"]
                    if not nxt:
                        errors.append(f"Transition {site_key}.{cur}->{goal_sub} missing 'via'")
                        break
                    if nxt in visited and nxt != goal_sub:
                        errors.append(f"Routing cycle in {site_key} from '{start_sub}' to '{goal_sub}': hit '{nxt}' twice")
                        break
                    visited.add(nxt)
                    cur = nxt
                    steps += 1
                    if steps > 8:
                        errors.append(f"Exceeded max hops in {site_key}: {start_sub} -> {goal_sub}")
                        break

    if errors:
        raise RuntimeError("Navigation graph validation failed:\n  - " + "\n  - ".join(errors))


def build_dig_sites_lua() -> list[str]:
    lines = ["Locations.DIG_SITES = {"]
    for site_key, sdef in DIG_SITES_SPEC.items():
        al, ax, az = sdef["arrival"]
        dyn_str = "nil" if sdef["mapDynId"] is None else str(sdef["mapDynId"])
        titems = "{ " + ", ".join(f'"{lua_escape(t)}"' for t in sdef["travelItems"]) + " }" if sdef["travelItems"] else "{}"
        lines.append(f'    ["{lua_escape(site_key)}"] = {{')
        lines.append(f'        name = "{lua_escape(sdef["name"])}",')
        lines.append(f"        arrival = {{ level = {al}, x = {ax}, z = {az} }},")
        lines.append(f"        mapDynId = {dyn_str},")
        lines.append(f"        travelItems = {titems},")
        lines.append("        zones = {")
        for z in sdef["zones"]:
            lvl_prefix = f"level = {z['level']}, " if z["level"] is not None else ""
            lines.append(
                f'            {{ {lvl_prefix}minX = {z["minX"]}, maxX = {z["maxX"]}, minZ = {z["minZ"]}, maxZ = {z["maxZ"]}, sub = "{lua_escape(z["sub"])}" }},'
            )
        lines.append("        },")
        lines.append("    },")
    lines.append("}")
    return lines


def build_transitions_lua(trans_spec: dict[str, dict[str, dict[str, dict]]]) -> list[str]:
    lines = [
        "-- Multi-stage intra-dig-site transitions (programmatically extracted & plane/BFS-verified):",
        "-- [siteKey][fromSub][toSub] = { level, x, z, label, candidates?, cfg?, objIds?, dlg?, alt? }",
        "Locations.TRANSITIONS = {",
    ]
    for site_key, site_map in trans_spec.items():
        lines.append(f'    ["{lua_escape(site_key)}"] = {{')
        for from_sub, targets in site_map.items():
            lines.append(f"        {from_sub} = {{")
            pad = max(len(k) for k in targets.keys())
            for to_sub, tr in targets.items():
                lines.append(f"            {to_sub.ljust(pad)} = {fmt_tr_spec(tr)},")
            lines.append("        },")
        lines.append("    },")
    lines.append("}")
    return lines


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scratch-dir", type=Path, default=None)
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    scratch = args.scratch_dir
    if (
        not args.refresh
        and scratch
        and (scratch / "wiki_arch_pages.json").is_file()
        and (scratch / "transform_data.json").is_file()
    ):
        bundle = json.loads((scratch / "wiki_arch_pages.json").read_text(encoding="utf-8"))
        transforms = json.loads((scratch / "transform_data.json").read_text(encoding="utf-8"))
    else:
        bundle, transforms = fetch_wiki_bundle()

    by_id = {z["id"]: z for z in transforms}

    if not args.refresh and scratch and (scratch / "wiki_transitions.json").is_file():
        transitions_data = json.loads((scratch / "wiki_transitions.json").read_text(encoding="utf-8"))
        # Convert JSON lists back to tuples
        def to_tuples(v):
            if isinstance(v, list):
                if len(v) == 3 and all(isinstance(x, int) for x in v):
                    return (v[0], v[1], v[2])
                return [to_tuples(x) for x in v]
            if isinstance(v, dict):
                return {k: to_tuples(val) for k, val in v.items()}
            return v
        transitions_data = to_tuples(transitions_data)
    else:
        transitions_data = extract_transitions_data(by_id)
        if scratch and scratch.is_dir():
            (scratch / "wiki_transitions.json").write_text(json.dumps(transitions_data, indent=2), encoding="utf-8")

    hotspots_map: dict[str, tuple[str, str, list[tuple[int, int, int]]]] = {}
    for title in sorted(bundle["hotspots"]):
        if title == "Excavation hotspots":
            continue
        wt = bundle["pages"].get(title, "")
        cs = parse_coords_from_wikitext(by_id, wt)
        if not cs:
            continue
        clean_name = re.sub(r"\s*\([^)]+\)$", "", title).strip()
        name_m = re.search(r"\|\s*name\s*=\s*([^\n|}]+)", wt)
        raw_name = name_m.group(1).strip() if name_m else clean_name
        site_m = re.search(r"\|\s*digsite\s*=\s*([^\n|}]+)", wt)
        site = site_m.group(1).strip() if site_m else ""
        if site.lower() in ("none", ""):
            loc_m = re.search(r"\|\s*location\s*=\s*([^\n|}]+)", wt)
            loc_str = loc_m.group(1) if loc_m else ""
            if "Campus" in loc_str or "Guild" in loc_str:
                site = "Archaeology Campus"
            elif "Orthen" in loc_str or "Anachronia" in loc_str or "Rex Matriarch" in loc_str:
                site = "Orthen"
            elif "Senntisten" in loc_str:
                site = "Senntisten"
            elif "Harvest Hollow" in loc_str:
                site = "Harvest Hollow"
            elif "Memorial to Guthix" in loc_str:
                site = "Memorial to Guthix"
        site = re.sub(r"\s*Dig Site$", "", site, flags=re.IGNORECASE).strip()

        key = normalize_key(raw_name)
        if key in hotspots_map:
            prev_name, prev_site, prev_cs = hotspots_map[key]
            merged = list(dict.fromkeys(prev_cs + cs))
            hotspots_map[key] = (prev_name, prev_site or site, merged)
        else:
            hotspots_map[key] = (raw_name, site, cs)

    caches_map: dict[str, list[tuple[int, int, int]]] = {}
    for title in sorted(bundle["caches"]):
        if title == "Material caches":
            continue
        wt = bundle["pages"].get(title, "")
        cs = parse_coords_from_wikitext(by_id, wt)
        if not cs:
            continue
        m = re.match(r"^Material cache \((.+)\)$", title, flags=re.IGNORECASE)
        mat_name = m.group(1).strip().lower() if m else title.lower()
        caches_map[mat_name] = cs

    trans_spec = build_transitions_spec(transitions_data)
    validate_navigation_graph(trans_spec, hotspots_map, caches_map)

    print(
        f"Extracted & verified {len(hotspots_map)} normalized hotspots, {len(caches_map)} material caches, "
        f"and {len(trans_spec)} dig site transition graphs (0 plane/zone/BFS errors)."
    )

    lua_lines = [
        "-- data/locations.lua",
        "-- Dig site zones, multi-stage transition graph, and exact world coordinates ({level, x, z})",
        "-- for Archaeology excavation hotspots, material caches, and sub-zone doors/portals/lifts.",
        "-- Generated via `python scripts/generate_locations.py`; dynamically supplemented at runtime",
        "-- by `ARCH_SITE` DBTables and live `LocList` discovery.",
        "",
        'local Hotspots = require("data/hotspots")',
        'local Utils    = require("core/utils")',
        "",
        "local Locations = {}",
        "",
        "-- Archaeology Campus / Guild Dig sites map table (object 116436, arch_planning_map)",
        "Locations.CAMPUS = {",
        '    name = "Archaeology Campus",',
        "    mapTableCoord = { level = 0, x = 3327, z = 3373 },",
        '    mapTableCfg   = "arch_planning_map",',
        "    mapTableObjIds = { 116436 },",
        "    zones = {",
        "        { minX = 3305, maxX = 3405, minZ = 3345, maxZ = 3418 }, -- surface & guild floors",
        "    },",
        "}",
        "",
        "Locations.GENERIC_TRAVEL_ITEMS = {",
        '    "archaeology journal",',
        '    "master archaeologist",',
        '    "archaeology teleport",',
        "}",
        "",
        "-- Canonical Dig Sites: arrival tile from Dig sites map (667), default 667:11 dynamicID,",
        "-- zone bounding boxes (nil level = any plane in that X/Z box), and extra travel items.",
    ]
    lua_lines.extend(build_dig_sites_lua())
    lua_lines.append("")
    lua_lines.extend(build_transitions_lua(trans_spec))
    lua_lines.append("")
    lua_lines.append("-- Normalized hotspot key -> { site = <digSiteKey>, coords = { {level, x, z}, ... } }")
    lua_lines.append("Locations.HOTSPOTS = {")

    for key in sorted(hotspots_map.keys()):
        raw_name, site, cs = hotspots_map[key]
        lua_lines.append(
            f'    ["{lua_escape(key)}"] = {{ name = "{lua_escape(raw_name)}", site = "{lua_escape(site)}", coords = {format_coord_list(cs)} }},'
        )
    lua_lines.append("}")
    lua_lines.append("")

    lua_lines.append("-- Lowercase material name -> { {level, x, z}, ... } for Material Caches")
    lua_lines.append("Locations.CACHES = {")
    for mat_lower in sorted(caches_map.keys()):
        cs = caches_map[mat_lower]
        lua_lines.append(f'    ["{lua_escape(mat_lower)}"] = {format_coord_list(cs)},')
    lua_lines.append("}")
    lua_lines.append("")

    lua_helpers = """
local function normKey(str)
    if Hotspots and Hotspots.normalizeKey then
        return Hotspots.normalizeKey(str)
    end
    return Utils.normalizeName(str or "")
end

--- Checks which dig site and sub-zone a coordinate `(level, x, z)` falls inside.
function Locations.findZoneAt(coord)
    if not coord or not coord.x or not coord.z then return nil, nil end
    local px, pz, pl = coord.x, coord.z, coord.level or 0
    for siteKey, site in pairs(Locations.DIG_SITES) do
        for _, z in ipairs(site.zones or {}) do
            if (z.level == nil or z.level == pl)
                and px >= z.minX and px <= z.maxX
                and pz >= z.minZ and pz <= z.maxZ then
                return siteKey, z.sub
            end
        end
    end
    return nil, nil
end

function Locations.isAtCampus(coord)
    if not coord or not coord.x or not coord.z then return false end
    for _, z in ipairs(Locations.CAMPUS.zones) do
        if coord.x >= z.minX and coord.x <= z.maxX and coord.z >= z.minZ and coord.z <= z.maxZ then
            return true
        end
    end
    return false
end

--- Resolves canonical Dig Site key from a DBTable site name or location string.
function Locations.resolveDigSiteKey(rawText)
    if not rawText or rawText == "" then return nil end
    if Locations.DIG_SITES[rawText] then return rawText end
    local lower = string.lower(rawText)
    for k in pairs(Locations.DIG_SITES) do
        if string.find(lower, string.lower(k), 1, true) then
            return k
        end
    end
    if string.find(lower, "guild", 1, true) or string.find(lower, "campus", 1, true) or string.find(lower, "tutorial", 1, true) then
        return "Archaeology Campus"
    end
    return nil
end

--- Resolves dynamic map button ID(s) on interface 667:11 for a site name, preferring live DBTable `ARCH_SITE` index.
local function collectMapDynIds(siteNames, dynMap)
    for _, sName in ipairs(siteNames) do
        local dynId = nil
        if Hotspots and Hotspots.DIG_SITES then
            local live = Hotspots.DIG_SITES[sName] or Hotspots.DIG_SITES[string.lower(sName)]
            if live and live.mapDynId ~= nil then
                dynId = live.mapDynId
            end
        end
        if dynId == nil then
            local canon = Locations.resolveDigSiteKey(sName)
            local site = canon and Locations.DIG_SITES[canon]
            if site and site.mapDynId ~= nil then
                dynId = site.mapDynId
            end
        end
        if dynId ~= nil then
            dynMap[dynId] = true
        end
    end
end

local function expandTupleCoords(tuples)
    local out = {}
    for _, t in ipairs(tuples or {}) do
        local c = { level = t[1] or 0, x = t[2], z = t[3] }
        local sKey, sub = Locations.findZoneAt(c)
        c.siteKey = sKey
        c.sub = sub
        out[#out + 1] = c
    end
    return out
end

function Locations.getArtefactFocusSpec(item)
    if not item or not item.artefact then return nil end
    local art = item.artefact
    local loc = art.location or ""
    local hotspotRaw = loc:match("^(.-)%s*%(") or loc
    hotspotRaw = Utils.trim(hotspotRaw)
    local siteInParens = loc:match("%((.-)%)")

    local hDef, matchedName = nil, nil
    if Hotspots and Hotspots.findMatch and hotspotRaw ~= "" then
        hDef, matchedName = Hotspots.findMatch(hotspotRaw)
    end
    local hKey = normKey(matchedName or hotspotRaw)
    local hEntry = Locations.HOTSPOTS[hKey] or Locations.HOTSPOTS[normKey(hotspotRaw)]

    local siteNames = {}
    if hDef and hDef.digSite then table.insert(siteNames, hDef.digSite) end
    if siteInParens and siteInParens ~= "" then table.insert(siteNames, siteInParens) end
    if hEntry and hEntry.site and hEntry.site ~= "" then table.insert(siteNames, hEntry.site) end

    local primarySite = nil
    for _, sn in ipairs(siteNames) do
        primarySite = Locations.resolveDigSiteKey(sn) or sn
        if primarySite then break end
    end

    local dynMap = {}
    collectMapDynIds(siteNames, dynMap)

    local spotCoords = expandTupleCoords(hEntry and hEntry.coords)
    local focusKeys = {}
    if hKey ~= "" then focusKeys["spot:" .. hKey] = true end
    if hotspotRaw ~= "" then focusKeys["spot:" .. normKey(hotspotRaw)] = true end

    local travelItems = {}
    for _, p in ipairs(Locations.GENERIC_TRAVEL_ITEMS) do travelItems[#travelItems + 1] = p end
    local siteDef = primarySite and Locations.DIG_SITES[primarySite]
    for _, p in ipairs((siteDef and siteDef.travelItems) or {}) do travelItems[#travelItems + 1] = p end

    return {
        kind         = "artefact",
        key          = art.name,
        label        = matchedName or (hotspotRaw ~= "" and hotspotRaw) or art.name,
        itemName     = art.name,
        damagedName  = art.damagedName,
        itemId       = art.restoredId or art.id,
        hotspotName  = matchedName or (hotspotRaw ~= "" and hotspotRaw) or nil,
        materialName = nil,
        siteKey      = primarySite,
        siteLabel    = (siteDef and siteDef.name) or primarySite or "Dig Site",
        mapDynIds    = dynMap,
        spotCoords   = spotCoords,
        focusKeys    = focusKeys,
        travelItems  = travelItems,
    }
end

-- Overworld material caches located outside the 9 canonical Archaeology Dig Sites
Locations.WORLD_CACHE_HINTS = {
    ["animal furs"]    = { siteLabel = "Feldip Hills",     travel = "Travel to Feldip Hills (north of Oo'glog lodestone)" },
    ["goldrune"]       = { siteLabel = "Camdozaal Cavern", travel = "Travel to Camdozaal Cavern (inside Ice Mountain, north of Falador)" },
    ["leather scraps"] = { siteLabel = "Morytania North",  travel = "Travel to Morytania North (south of Slayer Tower / Canifis lodestone)" },
    ["soapstone"]      = { siteLabel = "Waiko (The Arc)",  travel = "Travel to Waiko in The Arc (Port Sarim boat or Waiko teleport)" },
    ["vellum"]         = { siteLabel = "First Tower",      travel = "Travel to First Tower (Rune Essence portal at Wizards' Tower)" },
    ["white oak"]      = { siteLabel = "Ice Mountain",     travel = "Travel to Ice Mountain (north-west of Edgeville / Monastery)" },
}

function Locations.getMaterialFocusSpec(item, prioritiseCaches)
    if not item or not item.material then return nil end
    local mat = item.material
    local matName = mat.name or item.name or ""
    local matLower = string.lower(matName)
    local wantCachesOnly = (prioritiseCaches ~= false)

    local tupleList = {}
    local seenCoord = {}
    local function addTuples(ts)
        for _, t in ipairs(ts or {}) do
            local ck = (t[1] or 0) * 268435456 + t[2] * 16384 + t[3]
            if not seenCoord[ck] then
                seenCoord[ck] = true
                tupleList[#tupleList + 1] = t
            end
        end
    end

    -- 1. Material caches for this material (100% gather chance)
    local cacheTuples = Locations.CACHES[matLower]
    local hasCaches = (cacheTuples ~= nil and #cacheTuples > 0)
    local useCachesOnly = (wantCachesOnly and hasCaches)
    addTuples(cacheTuples)

    local focusKeys = { ["cache:" .. matLower] = true }
    local siteNames = {}
    local seenSites = {}
    local function addSite(s)
        if s and s ~= "" and not seenSites[s] then
            seenSites[s] = true
            siteNames[#siteNames + 1] = s
        end
    end

    -- 2. Include excavation hotspots only when Caches-Only mode is OFF (or if a material has no caches)
    if not useCachesOnly then
        for _, cSite in ipairs(mat.caches or {}) do
            addSite(cSite)
        end
        for hName, def in pairs((Hotspots and Hotspots.BY_NAME) or {}) do
            for _, m in ipairs(def.materials or {}) do
                if string.lower(m) == matLower then
                    local hk = normKey(hName)
                    focusKeys["spot:" .. hk] = true
                    if def.digSite then addSite(def.digSite) end
                    local hEntry = Locations.HOTSPOTS[hk]
                    if hEntry then
                        addTuples(hEntry.coords)
                        if hEntry.site then addSite(hEntry.site) end
                    end
                    break
                end
            end
        end
    end

    local spotCoords = expandTupleCoords(tupleList)
    for _, sc in ipairs(spotCoords) do
        if sc.siteKey then addSite(sc.siteKey) end
    end

    local dynMap = {}
    collectMapDynIds(siteNames, dynMap)

    local primarySite = nil
    local allSites = {}
    for _, sn in ipairs(siteNames) do
        local canon = Locations.resolveDigSiteKey(sn) or sn
        if canon then
            if not primarySite then primarySite = canon end
            allSites[canon] = true
        end
    end

    local worldHint = (not primarySite) and Locations.WORLD_CACHE_HINTS[matLower] or nil
    local travelItems = {}
    if primarySite then
        for _, p in ipairs(Locations.GENERIC_TRAVEL_ITEMS) do travelItems[#travelItems + 1] = p end
        for sk in pairs(allSites) do
            local sd = Locations.DIG_SITES[sk]
            for _, p in ipairs((sd and sd.travelItems) or {}) do travelItems[#travelItems + 1] = p end
        end
    end

    local siteLabel = (worldHint and worldHint.siteLabel)
        or (primarySite and ((Locations.DIG_SITES[primarySite] and Locations.DIG_SITES[primarySite].name) or primarySite))
        or "World Cache"

    return {
        kind         = "material",
        key          = matName,
        label        = useCachesOnly and ("Material cache (" .. matLower .. ")") or matName,
        itemName     = matName,
        itemId       = mat.id,
        hotspotName  = nil,
        materialName = matName,
        cacheOnly    = useCachesOnly,
        offsiteHint  = worldHint and worldHint.travel or nil,
        siteKey      = primarySite,
        allSites     = allSites,
        siteLabel    = siteLabel,
        mapDynIds    = dynMap,
        spotCoords   = spotCoords,
        focusKeys    = focusKeys,
        travelItems  = travelItems,
    }
end

local function resolveBestTransitionPoint(tr, pCoord)
    if tr.alt and (tr.alt.level or 0) == (pCoord.level or 0) then
        local altCheb = math.max(math.abs(tr.alt.x - pCoord.x), math.abs(tr.alt.z - pCoord.z))
        if altCheb <= (tr.alt.radius or 48) then
            return { level = tr.alt.level or 0, x = tr.alt.x, z = tr.alt.z }, altCheb, tr.alt.label or tr.label, tr.alt.cfg or tr.cfg, tr.alt.objIds, tr.alt.dlg
        end
    end
    if tr.candidates then
        local bestPt, bestD = nil, 999999999
        for _, tup in ipairs(tr.candidates) do
            local tl, tx, tz = tup[1] or 0, tup[2], tup[3]
            if tl == (pCoord.level or 0) then
                local d = math.max(math.abs(tx - pCoord.x), math.abs(tz - pCoord.z))
                if d < bestD then
                    bestD = d
                    bestPt = { level = tl, x = tx, z = tz }
                end
            end
        end
        if bestPt then
            return bestPt, bestD, tr.label, tr.cfg, tr.objIds, tr.dlg
        end
    end
    local d = math.max(math.abs(tr.x - pCoord.x), math.abs(tr.z - pCoord.z))
    return { level = tr.level or 0, x = tr.x, z = tr.z }, d, tr.label, tr.cfg, tr.objIds, tr.dlg
end

--- Given player position `pCoord` and `focusTarget`, resolves the current multi-stage step:
--- Returns `{ stage = "offsite"|"campus"|"transition"|"onsite", targetCoord = ..., label = ..., cfgPattern = ..., objIds = ..., dialogTerms = ... }`
function Locations.resolveGuidanceStep(focusTarget, pCoord, extraLearnedCoords)
    if not focusTarget or not pCoord or not pCoord.x or not pCoord.z then
        return nil
    end
    local curSite, curSub = Locations.findZoneAt(pCoord)
    local allCoords = {}
    for _, c in ipairs(focusTarget.spotCoords or {}) do allCoords[#allCoords + 1] = c end
    for _, c in ipairs(extraLearnedCoords or {}) do
        if c.x and c.z then
            local sk, sb = Locations.findZoneAt(c)
            allCoords[#allCoords + 1] = { level = c.level or 0, x = c.x, z = c.z, siteKey = sk, sub = sb }
        end
    end

    -- 1. Check if ANY target spot coordinate is already in the same sub-zone (or within 180 tiles if unzoned)!
    local bestSameRegion, bestSameDist = nil, 999999999
    for _, sc in ipairs(allCoords) do
        if (sc.level or 0) == (pCoord.level or 0) then
            local sameSub = (not curSub or not sc.sub) or (sc.siteKey == curSite and sc.sub == curSub)
            if sameSub then
                local cheb = math.max(math.abs(sc.x - pCoord.x), math.abs(sc.z - pCoord.z))
                if cheb <= 180 and cheb < bestSameDist then
                    bestSameDist = cheb
                    bestSameRegion = sc
                end
            end
        end
    end
    if bestSameRegion then
        return {
            stage       = "onsite",
            targetCoord = bestSameRegion,
            label       = focusTarget.label,
        }
    end

    -- 2. Check if the player IS at one of the target's Dig Sites, in a sub-zone that transitions toward a spot!
    if curSite and curSub then
        local siteTrans = Locations.TRANSITIONS[curSite]
        local fromMap = siteTrans and siteTrans[curSub]
        if fromMap then
            local bestStep, bestDist = nil, 999999999
            for _, sc in ipairs(allCoords) do
                if sc.siteKey == curSite and sc.sub and sc.sub ~= curSub then
                    local tr = fromMap[sc.sub]
                    if tr then
                        local pt, d, lbl, cfg, objIds, dlg = resolveBestTransitionPoint(tr, pCoord)
                        if pt and d < bestDist then
                            bestDist = d
                            bestStep = {
                                stage       = "transition",
                                targetCoord = pt,
                                label       = lbl,
                                cfgPattern  = cfg,
                                objIds      = objIds,
                                dialogTerms = dlg,
                            }
                        end
                    end
                end
            end
            if bestStep then
                return bestStep
            end
        end
    end

    -- 3. Player is NOT at the dig site yet!
    local destSite = focusTarget.siteKey
    if focusTarget.allSites and curSite and focusTarget.allSites[curSite] then
        destSite = curSite
    end
    local siteDef = destSite and Locations.DIG_SITES[destSite]
    local siteName = (siteDef and siteDef.name) or focusTarget.siteLabel or "Dig Site"
    local hasMapButton = (focusTarget.mapDynIds and next(focusTarget.mapDynIds) ~= nil)

    if focusTarget.offsiteHint then
        return {
            stage       = "offsite",
            targetCoord = nil,
            label       = focusTarget.offsiteHint,
        }
    end

    if Locations.isAtCampus(pCoord) and hasMapButton then
        return {
            stage       = "campus",
            targetCoord = Locations.CAMPUS.mapTableCoord,
            label       = "View Dig sites map -> " .. siteName,
            cfgPattern  = Locations.CAMPUS.mapTableCfg,
            objIds      = Locations.CAMPUS.mapTableObjIds,
        }
    end

    if hasMapButton then
        return {
            stage       = "offsite",
            targetCoord = nil,
            label       = "Travel to " .. siteName .. ": Teleport via Archaeology journal -> Dig sites map",
        }
    elseif siteDef and siteDef.arrival then
        return {
            stage       = "offsite",
            targetCoord = nil,
            label       = "Travel to " .. siteName .. ": Teleport via Archaeology journal",
        }
    end

    return {
        stage       = "offsite",
        targetCoord = nil,
        label       = "Travel to " .. siteName .. " (" .. tostring(focusTarget.label) .. ")",
    }
end

return Locations
"""
    lua_lines.append(lua_helpers.lstrip("\n"))

    out_path = repo_root / "data" / "locations.lua"
    out_path.write_text("\n".join(lua_lines), encoding="utf-8", newline="\n")
    print(f"Wrote {out_path} ({out_path.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
