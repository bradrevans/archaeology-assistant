-- data/locations.lua
-- Dig site zones, multi-stage transition graph, and exact world coordinates ({level, x, z})
-- for Archaeology excavation hotspots, material caches, and sub-zone doors/portals/lifts.
-- Generated via `python scripts/generate_locations.py`; dynamically supplemented at runtime
-- by `ARCH_SITE` DBTables and live `LocList` discovery.

local Hotspots = require("data/hotspots")
local Utils    = require("core/utils")

local Locations = {}

-- Archaeology Campus / Guild Dig sites map table (object 116436, arch_planning_map)
Locations.CAMPUS = {
    name = "Archaeology Campus",
    mapTableCoord = { level = 0, x = 3327, z = 3373 },
    mapTableCfg   = "arch_planning_map",
    mapTableObjIds = { 116436 },
    zones = {
        { minX = 3305, maxX = 3405, minZ = 3345, maxZ = 3418 }, -- surface & guild floors
    },
}

Locations.GENERIC_TRAVEL_ITEMS = {
    "archaeology journal",
    "master archaeologist",
    "archaeology teleport",
}

-- Canonical Dig Sites: arrival tile from Dig sites map (667), default 667:11 dynamicID,
-- zone bounding boxes (nil level = any plane in that X/Z box), and extra travel items.
Locations.DIG_SITES = {
    ["Kharid-et"] = {
        name = "Kharid-et",
        arrival = { level = 0, x = 3345, z = 3194 },
        mapDynId = 0,
        travelItems = { "pontifex" },
        zones = {
            { level = 0, minX = 3330, maxX = 3395, minZ = 3160, maxZ = 3220, sub = "exterior" },
            { level = 0, minX = 2414, maxX = 2522, minZ = 7550, maxZ = 7642, sub = "barracks" },
            { level = 0, minX = 2432, maxX = 2446, minZ = 7368, maxZ = 7394, sub = "solitary" },
            { level = 0, minX = 2432, maxX = 2453, minZ = 7395, maxZ = 7425, sub = "solitary" },
            { level = 0, minX = 2448, maxX = 2496, minZ = 7358, maxZ = 7425, sub = "vault" },
            { level = 0, minX = 2235, maxX = 2285, minZ = 7560, maxZ = 7620, sub = "carcerem" },
            { level = 0, minX = 2620, maxX = 2692, minZ = 7548, maxZ = 7620, sub = "praetorium" },
        },
    },
    ["Everlight"] = {
        name = "Everlight",
        arrival = { level = 0, x = 3697, z = 3207 },
        mapDynId = 1,
        travelItems = {},
        zones = {
            { level = 0, minX = 3680, maxX = 3845, minZ = 3125, maxZ = 3320, sub = "surface" },
            { minX = 2300, maxX = 2372, minZ = 7420, maxZ = 7620, sub = "underwater" },
        },
    },
    ["Infernal Source"] = {
        name = "Infernal Source",
        arrival = { level = 0, x = 3271, z = 3505 },
        mapDynId = 2,
        travelItems = {},
        zones = {
            { level = 0, minX = 3250, maxX = 3315, minZ = 3480, maxZ = 3530, sub = "surface" },
            { level = 0, minX = 2558, maxX = 2623, minZ = 7294, maxZ = 7360, sub = "cellar" },
            { level = 0, minX = 2624, maxX = 2690, minZ = 7294, maxZ = 7360, sub = "disorder" },
            { level = 3, minX = 2558, maxX = 2690, minZ = 7358, maxZ = 7490, sub = "vestibule" },
            { level = 2, minX = 2558, maxX = 2690, minZ = 7358, maxZ = 7490, sub = "harrowing" },
            { level = 1, minX = 2558, maxX = 2690, minZ = 7358, maxZ = 7490, sub = "dagon" },
        },
    },
    ["Stormguard Citadel"] = {
        name = "Stormguard Citadel",
        arrival = { level = 0, x = 2680, z = 3403 },
        mapDynId = 3,
        travelItems = {},
        zones = {
            { level = 0, minX = 2655, maxX = 2705, minZ = 3380, maxZ = 3425, sub = "surface" },
            { level = 1, minX = 2300, maxX = 2564, minZ = 7036, maxZ = 7300, sub = "citadel" },
            { level = 3, minX = 2300, maxX = 2564, minZ = 7036, maxZ = 7300, sub = "howl" },
        },
    },
    ["Warforge"] = {
        name = "Warforge",
        arrival = { level = 0, x = 2409, z = 2825 },
        mapDynId = 4,
        travelItems = {},
        zones = {
            { level = 0, minX = 2375, maxX = 2440, minZ = 2805, maxZ = 2860, sub = "surface" },
            { level = 0, minX = 2368, maxX = 2431, minZ = 7294, maxZ = 7359, sub = "sanctum" },
            { level = 0, minX = 2274, maxX = 2306, minZ = 7351, maxZ = 7371, sub = "forge" },
            { level = 0, minX = 2238, maxX = 2367, minZ = 7294, maxZ = 7425, sub = "tunnels" },
        },
    },
    ["Orthen"] = {
        name = "Orthen",
        arrival = { level = 0, x = 3921, z = 4259 },
        mapDynId = 5,
        travelItems = {},
        zones = {
            { level = 1, minX = 5500, maxX = 5570, minZ = 2810, maxZ = 2880, sub = "nodon" },
            { minX = 5376, maxX = 5695, minZ = 2112, maxZ = 2943, sub = "anachronia_alt" },
            { minX = 3648, maxX = 4224, minZ = 4000, maxZ = 4544, sub = "anachronia" },
            { level = 0, minX = 1214, maxX = 1282, minZ = 62, maxZ = 130, sub = "outpost" },
            { level = 0, minX = 1214, maxX = 1282, minZ = 190, maxZ = 258, sub = "xolo" },
            { level = 1, minX = 1086, maxX = 1154, minZ = 190, maxZ = 258, sub = "moksha" },
            { level = 2, minX = 1086, maxX = 1154, minZ = 62, maxZ = 194, sub = "varanus" },
            { minX = 3840, maxX = 3968, minZ = 9792, maxZ = 9920, sub = "rex_lair" },
        },
    },
    ["Senntisten"] = {
        name = "Senntisten",
        arrival = { level = 0, x = 1784, z = 1296 },
        mapDynId = 6,
        travelItems = { "pontifex", "dig site pendant" },
        zones = {
            { level = 0, minX = 3315, maxX = 3395, minZ = 3415, maxZ = 3470, sub = "surface_gate" },
            { minX = 1600, maxX = 2048, minZ = 1024, maxZ = 1408, sub = "city" },
            { minX = 320, maxX = 384, minZ = 128, maxZ = 192, sub = "colosseum" },
        },
    },
    ["Daemonheim"] = {
        name = "Daemonheim",
        arrival = { level = 0, x = 3428, z = 3699 },
        mapDynId = 7,
        travelItems = { "ring of kinship" },
        zones = {
            { level = 0, minX = 3390, maxX = 3500, minZ = 3640, maxZ = 3775, sub = "castle_0" },
            { level = 1, minX = 3390, maxX = 3500, minZ = 3675, maxZ = 3775, sub = "castle_1" },
            { level = 1, minX = 2174, maxX = 2242, minZ = 9214, maxZ = 9282, sub = "depths" },
            { level = 2, minX = 2174, maxX = 2242, minZ = 9214, maxZ = 9282, sub = "depths_2" },
        },
    },
    ["Moonrise"] = {
        name = "Moonrise",
        arrival = { level = 0, x = 4418, z = 3443 },
        mapDynId = 8,
        travelItems = {},
        zones = {
            { level = 0, minX = 4305, maxX = 4490, minZ = 3390, maxZ = 3505, sub = "periphery" },
            { level = 1, minX = 3710, maxX = 3778, minZ = 7998, maxZ = 8066, sub = "depths" },
        },
    },
    ["Archaeology Campus"] = {
        name = "Archaeology Campus",
        arrival = { level = 0, x = 3336, z = 3378 },
        mapDynId = nil,
        travelItems = { "dig site pendant" },
        zones = {
            { minX = 3305, maxX = 3415, minZ = 3345, maxZ = 3425, sub = "campus" },
        },
    },
}

-- Multi-stage intra-dig-site transitions (programmatically extracted & plane/BFS-verified):
-- [siteKey][fromSub][toSub] = { level, x, z, label, candidates?, cfg?, objIds?, dlg?, alt? }
Locations.TRANSITIONS = {
    ["Kharid-et"] = {
        exterior = {
            barracks   = { level = 0, x = 3373, z = 3178, label = "Enter Kharid-et Fortress", cfg = "arch_kharidet_entrance", objIds = { 116925, 116926 }, dlg = { "main fortress", "fortress", "barracks" } },
            carcerem   = { level = 0, x = 3373, z = 3178, label = "Enter Kharid-et Fortress -> Prison Block", cfg = "arch_kharidet_entrance", objIds = { 116925, 116926 }, dlg = { "prison block", "carcerem", "prison", "main fortress", "fortress" } },
            solitary   = { level = 0, x = 3373, z = 3178, label = "Enter Kharid-et Fortress -> Prison Block", cfg = "arch_kharidet_entrance", objIds = { 116925, 116926 }, dlg = { "prison block", "carcerem", "prison", "main fortress", "fortress" } },
            praetorium = { level = 0, x = 3373, z = 3178, label = "Enter Kharid-et Fortress -> Praetorium", cfg = "arch_kharidet_entrance", objIds = { 116925, 116926 }, dlg = { "praetorium", "war table", "main fortress", "fortress", "barracks" } },
            vault      = { level = 0, x = 3373, z = 3178, label = "Enter Kharid-et Fortress -> Vault", cfg = "arch_kharidet_entrance", objIds = { 116925, 116926 }, dlg = { "vault of shadows", "vault", "main fortress", "fortress", "barracks" } },
        },
        barracks = {
            exterior   = { level = 0, x = 2448, z = 7625, label = "Exit Kharid-et Fortress (north tunnel)", cfg = "arch_kharidet", objIds = { 116927 } },
            carcerem   = { level = 0, x = 2437, z = 7584, label = "Enter Prison Block door", cfg = "arch_kharidet_doorway_large", objIds = { 116972, 116974 }, dlg = { "enter", "prison", "yes" } },
            solitary   = { level = 0, x = 2437, z = 7584, label = "Enter Prison Block door -> Solitary", cfg = "arch_kharidet_doorway_large", objIds = { 116972, 116974 }, dlg = { "enter", "prison", "yes" } },
            praetorium = { level = 0, x = 2466, z = 7590, label = "Enter Praetorium War Table", cfg = "arch_kharidet_praetorium_entrance", objIds = { 116937, 116938 }, dlg = { "praetorium", "enter", "yes" } },
            vault      = { level = 0, x = 2490, z = 7575, label = "Press Vault button to enter Vault", candidates = { {0,2490,7575}, {0,2479,7590} }, cfg = "button", objIds = { 116941, 116944 }, dlg = { "yes", "enter", "vault" } },
        },
        carcerem = {
            exterior   = { level = 0, x = 2247, z = 7610, label = "Exit Prison Block (north-west door) to Barracks", cfg = "door" },
            barracks   = { level = 0, x = 2247, z = 7610, label = "Exit Prison Block (north-west door) to Barracks", cfg = "door" },
            praetorium = { level = 0, x = 2247, z = 7610, label = "Exit Prison Block (north-west door) -> War Table", cfg = "door" },
            vault      = { level = 0, x = 2247, z = 7610, label = "Exit Prison Block (north-west door) to Barracks", cfg = "door" },
        },
        solitary = {
            exterior   = { level = 0, x = 2436, z = 7407, label = "Exit Solitary Confinement (west door) to Prison Block", cfg = "door" },
            barracks   = { level = 0, x = 2436, z = 7407, label = "Exit Solitary Confinement (west door) to Prison Block", cfg = "door" },
            carcerem   = { level = 0, x = 2436, z = 7407, label = "Exit Solitary Confinement (west door) to Prison Block", cfg = "door" },
            praetorium = { level = 0, x = 2436, z = 7407, label = "Exit Solitary Confinement (west door) to Prison Block", cfg = "door" },
            vault      = { level = 0, x = 2436, z = 7407, label = "Exit Solitary Confinement (west door) to Prison Block", cfg = "door" },
        },
        praetorium = {
            exterior = { level = 0, x = 2652, z = 7581, label = "Exit Praetorium War Table", cfg = "arch_kharidet_praetorium_exit", objIds = { 116939 } },
            barracks = { level = 0, x = 2652, z = 7581, label = "Exit Praetorium War Table", cfg = "arch_kharidet_praetorium_exit", objIds = { 116939 } },
            carcerem = { level = 0, x = 2652, z = 7581, label = "Exit Praetorium War Table", cfg = "arch_kharidet_praetorium_exit", objIds = { 116939 } },
            solitary = { level = 0, x = 2652, z = 7581, label = "Exit Praetorium War Table", cfg = "arch_kharidet_praetorium_exit", objIds = { 116939 } },
            vault    = { level = 0, x = 2652, z = 7581, label = "Exit Praetorium War Table", cfg = "arch_kharidet_praetorium_exit", objIds = { 116939 } },
        },
        vault = {
            exterior   = { level = 0, x = 2491, z = 7368, label = "Use Vault exit to Fortress", candidates = { {0,2491,7368}, {0,2494,7387} }, cfg = "arch_kharidet_vault_exit", objIds = { 116960, 116963 } },
            barracks   = { level = 0, x = 2491, z = 7368, label = "Use Vault exit to Fortress", candidates = { {0,2491,7368}, {0,2494,7387} }, cfg = "arch_kharidet_vault_exit", objIds = { 116960, 116963 } },
            carcerem   = { level = 0, x = 2449, z = 7381, label = "Use Ice Vault exit to Prison Block", cfg = "arch_kharidet_vault_exit_ice", objIds = { 116961 } },
            solitary   = { level = 0, x = 2449, z = 7381, label = "Use Ice Vault exit to Prison Block", cfg = "arch_kharidet_vault_exit_ice", objIds = { 116961 } },
            praetorium = { level = 0, x = 2464, z = 7407, label = "Use Shadow Vault exit to Praetorium", cfg = "arch_kharidet_vault_exit_shadow", objIds = { 116962 } },
        },
    },
    ["Everlight"] = {
        surface = {
            underwater = { level = 0, x = 3761, z = 3150, label = "Enter Acropolis underground door", objIds = { 116492, 116494 }, dlg = { "underwater", "cave", "descend", "enter", "yes" } },
        },
        underwater = {
            surface = { level = 1, x = 2356, z = 7499, label = "Exit door to Everlight surface", objIds = { 116499 }, dlg = { "surface", "ascend", "exit", "leave", "yes" } },
        },
    },
    ["Infernal Source"] = {
        surface = {
            cellar    = { level = 0, x = 3261, z = 3503, label = "Descend Infernal Source lift -> Star Lodge Cellar", cfg = "lift", dlg = { "star lodge", "cellar" } },
            disorder  = { level = 0, x = 3261, z = 3503, label = "Descend Infernal Source lift -> Dungeon of Disorder", cfg = "lift", dlg = { "dungeon of disorder", "disorder", "star lodge", "cellar" } },
            vestibule = { level = 0, x = 3261, z = 3503, label = "Descend Infernal Source lift -> Vestibule of Futility", cfg = "lift", dlg = { "vestibule of futility", "vestibule", "the source", "dungeon of disorder", "disorder", "star lodge", "cellar" } },
            harrowing = { level = 0, x = 3261, z = 3503, label = "Descend Infernal Source lift -> The Harrowing", cfg = "lift", dlg = { "the harrowing", "harrowing", "vestibule of futility", "vestibule", "dungeon of disorder", "disorder", "star lodge", "cellar" } },
            dagon     = { level = 0, x = 3261, z = 3503, label = "Descend Infernal Source lift -> Dagon Overlook", cfg = "lift", dlg = { "dagon overlook", "dagon", "the harrowing", "harrowing", "vestibule of futility", "vestibule", "dungeon of disorder", "disorder", "star lodge", "cellar" } },
        },
        cellar = {
            surface   = { level = 0, x = 2584, z = 7320, label = "Ascend Star Lodge lift to surface", cfg = "lift", dlg = { "surface", "up", "exit", "yes" } },
            disorder  = { level = 0, x = 2591, z = 7336, label = "Climb down Secret Passage behind hearth", cfg = "arch_infernalsource_cellar_fireplace", objIds = { 116698, 116699 }, dlg = { "yes", "enter", "climb" } },
            vestibule = { level = 0, x = 2591, z = 7336, label = "Climb down Secret Passage behind hearth", cfg = "arch_infernalsource_cellar_fireplace", objIds = { 116698, 116699 }, dlg = { "yes", "enter", "climb" } },
            harrowing = { level = 0, x = 2591, z = 7336, label = "Climb down Secret Passage behind hearth", cfg = "arch_infernalsource_cellar_fireplace", objIds = { 116698, 116699 }, dlg = { "yes", "enter", "climb" } },
            dagon     = { level = 0, x = 2591, z = 7336, label = "Climb down Secret Passage behind hearth", cfg = "arch_infernalsource_cellar_fireplace", objIds = { 116698, 116699 }, dlg = { "yes", "enter", "climb" } },
        },
        disorder = {
            surface   = { level = 0, x = 2638, z = 7298, label = "Climb up stairs to Star Lodge Cellar" },
            cellar    = { level = 0, x = 2638, z = 7298, label = "Climb up stairs to Star Lodge Cellar" },
            vestibule = { level = 0, x = 2674, z = 7346, label = "Enter Dungeon of Disorder ritual portal", cfg = "portal", objIds = { 116732, 116734, 116735 }, dlg = { "vestibule", "enter", "yes" } },
            harrowing = { level = 0, x = 2674, z = 7346, label = "Enter Dungeon of Disorder ritual portal", cfg = "portal", objIds = { 116732, 116734, 116735 }, dlg = { "harrowing", "vestibule", "enter", "yes" } },
            dagon     = { level = 0, x = 2674, z = 7346, label = "Enter Dungeon of Disorder ritual portal", cfg = "portal", objIds = { 116732, 116734, 116735 }, dlg = { "dagon", "vestibule", "enter", "yes" } },
        },
        vestibule = {
            surface   = { level = 3, x = 2621, z = 7417, label = "Leave via Portal Chamber", cfg = "arch_research_infernalsource_vestibule", objIds = { 116787, 116788 }, dlg = { "surface", "leave", "exit", "disorder", "yes" } },
            cellar    = { level = 3, x = 2621, z = 7417, label = "Leave via Portal Chamber", cfg = "arch_research_infernalsource_vestibule", objIds = { 116787, 116788 }, dlg = { "cellar", "disorder", "leave", "exit", "yes" } },
            disorder  = { level = 3, x = 2621, z = 7417, label = "Leave via Portal Chamber", cfg = "arch_research_infernalsource_vestibule", objIds = { 116787, 116788 }, dlg = { "disorder", "leave", "exit", "yes" } },
            harrowing = { level = 3, x = 2669, z = 7375, label = "Enter red Dagon portal to The Harrowing", candidates = { {3,2669,7375}, {3,2685,7398}, {3,2680,7453}, {3,2624,7467} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116741, 116743, 116744, 116751 } },
            dagon     = { level = 3, x = 2564, z = 7428, label = "Enter red Dagon portal to Dagon Overlook", candidates = { {3,2564,7428}, {3,2586,7479} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116748, 116750 } },
        },
        harrowing = {
            dagon     = { level = 2, x = 2573, z = 7453, label = "Enter Capricorn portal to Dagon Overlook", cfg = "arch_infernalsource_malebranche_portal_10", objIds = { 116749 } },
            vestibule = { level = 2, x = 2640, z = 7396, label = "Enter red Dagon portal up to Vestibule", candidates = { {2,2640,7396}, {2,2651,7406}, {2,2651,7442}, {2,2621,7477} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116741, 116743, 116744, 116751 } },
            disorder  = { level = 2, x = 2640, z = 7396, label = "Enter red Dagon portal up to Vestibule", candidates = { {2,2640,7396}, {2,2651,7406}, {2,2651,7442}, {2,2621,7477} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116741, 116743, 116744, 116751 } },
            cellar    = { level = 2, x = 2640, z = 7396, label = "Enter red Dagon portal up to Vestibule", candidates = { {2,2640,7396}, {2,2651,7406}, {2,2651,7442}, {2,2621,7477} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116741, 116743, 116744, 116751 } },
            surface   = { level = 2, x = 2640, z = 7396, label = "Enter red Dagon portal up to Vestibule", candidates = { {2,2640,7396}, {2,2651,7406}, {2,2651,7442}, {2,2621,7477} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116741, 116743, 116744, 116751 } },
        },
        dagon = {
            harrowing = { level = 1, x = 2605, z = 7435, label = "Enter Capricorn portal up to The Harrowing", cfg = "arch_infernalsource_malebranche_portal_10", objIds = { 116749 } },
            vestibule = { level = 1, x = 2602, z = 7423, label = "Enter red Dagon portal up to Vestibule", candidates = { {1,2602,7423}, {1,2613,7442} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116748, 116750 } },
            disorder  = { level = 1, x = 2602, z = 7423, label = "Enter red Dagon portal up to Vestibule", candidates = { {1,2602,7423}, {1,2613,7442} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116748, 116750 } },
            cellar    = { level = 1, x = 2602, z = 7423, label = "Enter red Dagon portal up to Vestibule", candidates = { {1,2602,7423}, {1,2613,7442} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116748, 116750 } },
            surface   = { level = 1, x = 2602, z = 7423, label = "Enter red Dagon portal up to Vestibule", candidates = { {1,2602,7423}, {1,2613,7442} }, cfg = "arch_infernalsource_malebranche_portal", objIds = { 116748, 116750 } },
        },
    },
    ["Stormguard Citadel"] = {
        surface = {
            citadel = { level = 0, x = 2678, z = 3397, label = "Teleport via Stormguard portal", cfg = "arch_stormguard_entrance", objIds = { 117129 }, dlg = { "stormguard", "citadel", "keshik", "yes" } },
            howl    = { level = 0, x = 2678, z = 3397, label = "Teleport via Stormguard portal", cfg = "arch_stormguard_entrance", objIds = { 117129 }, dlg = { "howl", "workshop", "north-west", "northwest", "stormguard", "citadel", "yes" } },
        },
        citadel = {
            surface = { level = 1, x = 2455, z = 7167, label = "Exit via Stormguard portal", cfg = "arch_stormguard_exit", objIds = { 117130 }, dlg = { "temple of ikov", "ikov", "camp", "surface", "exit", "leave", "yes" } },
            howl    = { level = 1, x = 2409, z = 7151, label = "Interact with Gravitational core -> Howl's Workshop", cfg = "gravitational", objIds = { 117174, 117175 }, dlg = { "howl's workshop", "howl", "workshop", "up", "enter", "yes" } },
        },
        howl = {
            citadel = { level = 3, x = 2402, z = 7156, label = "Exit Howl's Workshop via Gravitational core", cfg = "gravitational", objIds = { 117174, 117175 }, dlg = { "research", "citadel", "down", "exit", "leave", "yes" } },
            surface = { level = 3, x = 2402, z = 7156, label = "Exit Howl's Workshop via Gravitational core", cfg = "gravitational", objIds = { 117174, 117175 }, dlg = { "temple of ikov", "research", "citadel", "down", "exit", "leave", "yes" } },
        },
    },
    ["Warforge"] = {
        surface = {
            sanctum = { level = 0, x = 2410, z = 2838, label = "Descend Warforge lift -> Crucible", cfg = "lift", dlg = { "the crucible", "crucible", "bandos", "sanctum" } },
            tunnels = { level = 0, x = 2410, z = 2838, label = "Descend Warforge lift -> Goblin Tunnels", cfg = "lift", dlg = { "goblin tunnels", "the tunnels", "tunnels" } },
            forge   = { level = 0, x = 2410, z = 2838, label = "Descend Warforge lift -> Thalmund's Forge", cfg = "lift", dlg = { "thalmund's forge", "the forge", "forge", "goblin tunnels", "the tunnels", "tunnels" } },
        },
        sanctum = {
            surface = { level = 0, x = 2389, z = 7326, label = "Ascend Warforge lift to surface", cfg = "lift", dlg = { "surface", "up", "exit", "yes" } },
            tunnels = { level = 0, x = 2398, z = 7327, label = "Enter Goblin Tunnels entrance", cfg = "arch_warforge_tunnels_entrance", objIds = { 117248 } },
            forge   = { level = 0, x = 2398, z = 7327, label = "Enter Goblin Tunnels entrance -> Forge", cfg = "arch_warforge_tunnels_entrance", objIds = { 117248 } },
        },
        tunnels = {
            sanctum = { level = 0, x = 2333, z = 7375, label = "Exit Goblin Tunnels to Crucible", cfg = "arch_warforge_tunnels_exit", objIds = { 117249 } },
            surface = { level = 0, x = 2333, z = 7375, label = "Exit Goblin Tunnels to Crucible", cfg = "arch_warforge_tunnels_exit", objIds = { 117249 } },
            forge   = { level = 0, x = 2297, z = 7372, label = "Enter Thalmund's Forge doors", candidates = { {0,2297,7372}, {0,2300,7350} }, cfg = "door", objIds = { 117252, 117254 }, dlg = { "enter", "forge", "yes" } },
        },
        forge = {
            tunnels = { level = 0, x = 2297, z = 7371, label = "Exit Thalmund's Forge doors to Tunnels", candidates = { {0,2297,7371}, {0,2300,7351} }, cfg = "door", objIds = { 117252, 117254 } },
            sanctum = { level = 0, x = 2297, z = 7371, label = "Exit Thalmund's Forge doors -> Crucible", candidates = { {0,2297,7371}, {0,2300,7351} }, cfg = "door", objIds = { 117252, 117254 } },
            surface = { level = 0, x = 2297, z = 7371, label = "Exit Thalmund's Forge doors -> Lift", candidates = { {0,2297,7371}, {0,2300,7351} }, cfg = "door", objIds = { 117252, 117254 } },
        },
    },
    ["Orthen"] = {
        anachronia = {
            varanus  = { level = 0, x = 3908, z = 4258, label = "Use Orthen teleportation device -> Crypt of Varanus", candidates = { {0,3908,4258}, {0,3780,4330}, {0,4049,4448}, {0,4119,4077} }, cfg = "teleportation device", objIds = { 119029, 119030, 119031, 119034 }, dlg = { "crypt of varanus", "varanus", "crypt" }, alt = { level = 0, x = 3792, z = 4336, radius = 48, label = "Enter Crypt of Varanus door", cfg = "door" } },
            outpost  = { level = 0, x = 3908, z = 4258, label = "Use Orthen teleportation device -> Observation Outpost", candidates = { {0,3908,4258}, {0,3780,4330}, {0,4049,4448}, {0,4119,4077} }, cfg = "teleportation device", objIds = { 119029, 119030, 119031, 119034 }, dlg = { "observation outpost", "outpost" }, alt = { level = 0, x = 4057, z = 4451, radius = 48, label = "Enter Observation Outpost door", cfg = "door" } },
            moksha   = { level = 0, x = 3908, z = 4258, label = "Use Orthen teleportation device -> Moksha Ritual Site", candidates = { {0,3908,4258}, {0,3780,4330}, {0,4049,4448}, {0,4119,4077} }, cfg = "teleportation device", objIds = { 119029, 119030, 119031, 119034 }, dlg = { "moksha ritual site", "moksha", "ritual site" }, alt = { level = 0, x = 3981, z = 4129, radius = 48, label = "Enter Moksha Ritual Site stairs", cfg = "arch_orthen_moksha_surface_entrance" } },
            xolo     = { level = 0, x = 3908, z = 4258, label = "Use Orthen teleportation device -> Xolo City", candidates = { {0,3908,4258}, {0,3780,4330}, {0,4049,4448}, {0,4119,4077} }, cfg = "teleportation device", objIds = { 119029, 119030, 119031, 119034 }, dlg = { "xolo city", "xolo" }, alt = { level = 0, x = 4141, z = 4077, radius = 48, label = "Enter Xolo City door", cfg = "arch_orthen_xolo_city_entrance" } },
            nodon    = { level = 0, x = 3972, z = 4322, label = "Enter Nodon Hibernatorium ruins", cfg = "door" },
            rex_lair = { level = 0, x = 4050, z = 4286, label = "Enter Rex Matriarch lair", cfg = "entrance" },
        },
        varanus = {
            anachronia = { level = 2, x = 1118, z = 102, label = "Exit Crypt of Varanus stairs", cfg = "arch_orthen_crypt_of_varanus_exit", objIds = { 119043 } },
            outpost    = { level = 2, x = 1118, z = 102, label = "Exit Crypt of Varanus -> Orthen teleportation device", cfg = "arch_orthen_crypt_of_varanus_exit", objIds = { 119043 } },
            moksha     = { level = 2, x = 1118, z = 102, label = "Exit Crypt of Varanus -> Orthen teleportation device", cfg = "arch_orthen_crypt_of_varanus_exit", objIds = { 119043 } },
            xolo       = { level = 2, x = 1118, z = 102, label = "Exit Crypt of Varanus -> Orthen teleportation device", cfg = "arch_orthen_crypt_of_varanus_exit", objIds = { 119043 } },
            nodon      = { level = 2, x = 1118, z = 102, label = "Exit Crypt of Varanus -> Anachronia", cfg = "arch_orthen_crypt_of_varanus_exit", objIds = { 119043 } },
            rex_lair   = { level = 2, x = 1118, z = 102, label = "Exit Crypt of Varanus -> Anachronia", cfg = "arch_orthen_crypt_of_varanus_exit", objIds = { 119043 } },
        },
        outpost = {
            anachronia = { level = 0, x = 1257, z = 108, label = "Exit Observation Outpost stairs", cfg = "arch_orthen_observation_outpost_exit", objIds = { 119050 } },
            varanus    = { level = 0, x = 1257, z = 108, label = "Exit Observation Outpost -> Orthen teleportation device", cfg = "arch_orthen_observation_outpost_exit", objIds = { 119050 } },
            moksha     = { level = 0, x = 1257, z = 108, label = "Exit Observation Outpost -> Orthen teleportation device", cfg = "arch_orthen_observation_outpost_exit", objIds = { 119050 } },
            xolo       = { level = 0, x = 1257, z = 108, label = "Exit Observation Outpost -> Orthen teleportation device", cfg = "arch_orthen_observation_outpost_exit", objIds = { 119050 } },
            nodon      = { level = 0, x = 1257, z = 108, label = "Exit Observation Outpost -> Anachronia", cfg = "arch_orthen_observation_outpost_exit", objIds = { 119050 } },
            rex_lair   = { level = 0, x = 1257, z = 108, label = "Exit Observation Outpost -> Anachronia", cfg = "arch_orthen_observation_outpost_exit", objIds = { 119050 } },
        },
        moksha = {
            anachronia = { level = 1, x = 1126, z = 204, label = "Use Orthen teleportation device or Stairs out", candidates = { {1,1126,204}, {1,1118,203} }, cfg = "arch_orthen_moksha", objIds = { 119029, 119034, 119065 }, dlg = { "base camp", "anachronia" } },
            varanus    = { level = 1, x = 1126, z = 204, label = "Use Orthen teleportation device -> Crypt of Varanus", candidates = { {1,1126,204}, {1,1118,203} }, cfg = "teleportation device", objIds = { 119029, 119034, 119065 }, dlg = { "crypt of varanus", "varanus", "crypt" } },
            outpost    = { level = 1, x = 1126, z = 204, label = "Use Orthen teleportation device -> Observation Outpost", candidates = { {1,1126,204}, {1,1118,203} }, cfg = "teleportation device", objIds = { 119029, 119034, 119065 }, dlg = { "observation outpost", "outpost" } },
            xolo       = { level = 1, x = 1126, z = 204, label = "Use Orthen teleportation device -> Xolo City", candidates = { {1,1126,204}, {1,1118,203} }, cfg = "teleportation device", objIds = { 119029, 119034, 119065 }, dlg = { "xolo city", "xolo" } },
            nodon      = { level = 1, x = 1126, z = 204, label = "Use Orthen teleportation device -> Base Camp", candidates = { {1,1126,204}, {1,1118,203} }, cfg = "teleportation device", objIds = { 119029, 119034, 119065 }, dlg = { "base camp", "anachronia" } },
            rex_lair   = { level = 1, x = 1126, z = 204, label = "Use Orthen teleportation device -> Base Camp", candidates = { {1,1126,204}, {1,1118,203} }, cfg = "teleportation device", objIds = { 119029, 119034, 119065 }, dlg = { "base camp", "anachronia" } },
        },
        xolo = {
            anachronia = { level = 0, x = 1247, z = 248, label = "Exit Xolo City stairs", cfg = "arch_orthen_xolo_city_exit", objIds = { 119067 } },
            varanus    = { level = 0, x = 1247, z = 248, label = "Exit Xolo City stairs", cfg = "arch_orthen_xolo_city_exit", objIds = { 119067 } },
            outpost    = { level = 0, x = 1247, z = 248, label = "Exit Xolo City stairs", cfg = "arch_orthen_xolo_city_exit", objIds = { 119067 } },
            moksha     = { level = 0, x = 1247, z = 248, label = "Exit Xolo City stairs", cfg = "arch_orthen_xolo_city_exit", objIds = { 119067 } },
            nodon      = { level = 0, x = 1247, z = 248, label = "Exit Xolo City stairs", cfg = "arch_orthen_xolo_city_exit", objIds = { 119067 } },
            rex_lair   = { level = 0, x = 1247, z = 248, label = "Exit Xolo City stairs", cfg = "arch_orthen_xolo_city_exit", objIds = { 119067 } },
        },
        nodon = {
            anachronia = { level = 1, x = 5534, z = 2847, label = "Exit Nodon Hibernatorium", cfg = "exit" },
            varanus    = { level = 1, x = 5534, z = 2847, label = "Exit Nodon Hibernatorium -> Anachronia", cfg = "exit" },
            outpost    = { level = 1, x = 5534, z = 2847, label = "Exit Nodon Hibernatorium -> Anachronia", cfg = "exit" },
            moksha     = { level = 1, x = 5534, z = 2847, label = "Exit Nodon Hibernatorium -> Anachronia", cfg = "exit" },
            xolo       = { level = 1, x = 5534, z = 2847, label = "Exit Nodon Hibernatorium -> Anachronia", cfg = "exit" },
            rex_lair   = { level = 1, x = 5534, z = 2847, label = "Exit Nodon Hibernatorium -> Anachronia", cfg = "exit" },
        },
        rex_lair = {
            anachronia = { level = 0, x = 3904, z = 9855, label = "Exit Rex Matriarch lair", cfg = "exit" },
            varanus    = { level = 0, x = 3904, z = 9855, label = "Exit Rex Matriarch lair -> Anachronia", cfg = "exit" },
            outpost    = { level = 0, x = 3904, z = 9855, label = "Exit Rex Matriarch lair -> Anachronia", cfg = "exit" },
            moksha     = { level = 0, x = 3904, z = 9855, label = "Exit Rex Matriarch lair -> Anachronia", cfg = "exit" },
            xolo       = { level = 0, x = 3904, z = 9855, label = "Exit Rex Matriarch lair -> Anachronia", cfg = "exit" },
            nodon      = { level = 0, x = 3904, z = 9855, label = "Exit Rex Matriarch lair -> Anachronia", cfg = "exit" },
        },
    },
    ["Senntisten"] = {
        surface_gate = {
            city      = { level = 0, x = 3332, z = 3452, label = "Enter Senntisten Ancient Door", cfg = "egwd_surface_entrance_door", objIds = { 119483 }, dlg = { "yes" } },
            colosseum = { level = 0, x = 3332, z = 3452, label = "Enter Senntisten Ancient Door", cfg = "egwd_surface_entrance_door", objIds = { 119483 }, dlg = { "yes" } },
        },
        city = {
            colosseum = { level = 0, x = 1664, z = 1308, label = "Enter Colosseum gateway (Non-combat)", cfg = "egwd_colosseum_entrance", objIds = { 120046 }, dlg = { "non-combat", "non combat", "yes" } },
        },
        colosseum = {
            city = { level = 0, x = 367, z = 156, label = "Exit Colosseum gate to Senntisten", cfg = "egwd_colosseum_exit", objIds = { 120047 } },
        },
    },
    ["Daemonheim"] = {
        castle_0 = {
            castle_1 = { level = 0, x = 3451, z = 3733, label = "Climb up Daemonheim Castle staircase", candidates = { {0,3451,3733}, {0,3447,3733} }, cfg = "rand_dragonkin_ruin_staircase", objIds = { 48611, 48612 } },
            depths   = { level = 0, x = 3461, z = 3751, label = "Enter Imposing Door to Daemonheim Depths", cfg = "arch_research_daemonheim_depths_door", objIds = { 130289, 130291 }, dlg = { "enter", "depths", "yes" } },
        },
        castle_1 = {
            castle_0 = { level = 1, x = 3451, z = 3737, label = "Climb down Daemonheim Castle staircase", candidates = { {1,3451,3737}, {1,3448,3737} }, cfg = "rand_dragonkin_ruin_staircase", objIds = { 50567, 50568 } },
            depths   = { level = 1, x = 3451, z = 3737, label = "Climb down Daemonheim Castle staircase -> Imposing Door", candidates = { {1,3451,3737}, {1,3448,3737} }, cfg = "rand_dragonkin_ruin_staircase", objIds = { 50567, 50568 } },
        },
        depths = {
            castle_0 = { level = 1, x = 2209, z = 9250, label = "Exit Daemonheim Depths via Imposing Door", candidates = { {1,2209,9250}, {1,2207,9218} }, cfg = "arch_research_daemonheim_depths_door_to_castle", objIds = { 130292 } },
            castle_1 = { level = 1, x = 2209, z = 9250, label = "Exit Daemonheim Depths via Imposing Door", candidates = { {1,2209,9250}, {1,2207,9218} }, cfg = "arch_research_daemonheim_depths_door_to_castle", objIds = { 130292 } },
        },
        depths_2 = {
            depths   = { level = 2, x = 2225, z = 9239, label = "Climb down Depths staircase", cfg = "arch_daemonheim_steps_upstairs", objIds = { 130301 } },
            castle_0 = { level = 2, x = 2225, z = 9239, label = "Climb down Depths staircase", cfg = "arch_daemonheim_steps_upstairs", objIds = { 130301 } },
            castle_1 = { level = 2, x = 2225, z = 9239, label = "Climb down Depths staircase", cfg = "arch_daemonheim_steps_upstairs", objIds = { 130301 } },
        },
    },
    ["Moonrise"] = {
        periphery = {
            depths = { level = 0, x = 4446, z = 3457, label = "Enter Moonrise Temple doors", cfg = "arch_moonrise_temple_entrance", objIds = { 137388 }, dlg = { "enter", "depths", "temple", "yes" } },
        },
        depths = {
            periphery = { level = 1, x = 3743, z = 8059, label = "Exit Moonrise Temple doors", cfg = "arch_moonrise_temple_exit", objIds = { 137389 } },
        },
    },
}

-- Normalized hotspot key -> { site = <digSiteKey>, coords = { {level, x, z}, ... } }
Locations.HOTSPOTS = {
    ["acropolis debris"] = { name = "Acropolis debris", site = "Everlight", coords = { {0,3750,3140}, {0,3749,3146}, {0,3753,3149} } },
    ["administratum debris"] = { name = "Administratum debris", site = "Kharid-et", coords = { {0,2447,7572}, {0,2448,7568}, {0,2450,7570} } },
    ["aetherium forge"] = { name = "Aetherium forge", site = "Stormguard Citadel", coords = { {3,2403,7147}, {3,2408,7148}, {3,2411,7141}, {3,2406,7142} } },
    ["amphitheatre debris"] = { name = "Amphitheatre debris", site = "Everlight", coords = { {0,3768,3283}, {0,3771,3286}, {0,3769,3290}, {0,3749,3293}, {0,3754,3294}, {0,3749,3299} } },
    ["ancient magick munitions"] = { name = "Ancient magick munitions", site = "Kharid-et", coords = { {0,2652,7587}, {0,2658,7586}, {0,2656,7587} } },
    ["animal trophies"] = { name = "Animal trophies", site = "Infernal Source", coords = { {3,2656,7397}, {3,2659,7392}, {3,2661,7399} } },
    ["arbour rubble"] = { name = "Arbour rubble", site = "Moonrise", coords = { {0,4408,3446}, {0,4408,3450}, {0,4411,3448} } },
    ["armarium debris"] = { name = "Armarium debris", site = "Kharid-et", coords = { {0,2488,7589}, {0,2486,7592}, {0,2490,7595} } },
    ["aughra remains"] = { name = "Aughra remains", site = "Orthen", coords = { {1,1101,213}, {1,1107,210}, {1,1110,205} } },
    ["autopsy table"] = { name = "Autopsy table", site = "Orthen", coords = { {0,1250,99}, {0,1246,95}, {0,1244,102}, {0,1238,98}, {0,1244,90} } },
    ["bandos sanctum debris"] = { name = "Bandos's sanctum debris", site = "Warforge", coords = { {0,2395,7342}, {0,2399,7346}, {0,2396,7349} } },
    ["barricade"] = { name = "Barricade", site = "Warforge", coords = { {0,2399,7328} } },
    ["bibliotheke debris"] = { name = "Bibliotheke debris", site = "Everlight", coords = { {0,3767,3147}, {0,3766,3144}, {0,3772,3148} } },
    ["big high war god shrine"] = { name = "Big High War God shrine", site = "Warforge", coords = { {0,2312,7407}, {0,2309,7408}, {0,2307,7410} } },
    ["blood altar"] = { name = "Blood altar", site = "Moonrise", coords = { {1,3742,8018}, {1,3745,8014}, {1,3745,8022} } },
    ["botanical reserve"] = { name = "Botanical reserve", site = "Daemonheim", coords = { {1,3436,3740}, {1,3438,3748}, {1,3439,3743} } },
    ["byzroth remains"] = { name = "Byzroth remains", site = "Infernal Source", coords = { {2,2604,7447}, {2,2597,7447}, {2,2594,7443}, {2,2591,7438}, {2,2594,7434}, {2,2591,7413}, {2,2595,7416}, {2,2589,7417} } },
    ["carcerem debris"] = { name = "Carcerem debris", site = "Kharid-et", coords = { {0,2262,7590}, {0,2264,7583}, {0,2267,7585} } },
    ["castle hall rubble"] = { name = "Castle hall rubble", site = "Daemonheim", coords = { {0,3430,3734}, {0,3434,3727}, {0,3436,3733} } },
    ["castra debris"] = { name = "Castra debris", site = "Kharid-et", coords = { {0,2441,7590}, {0,2442,7581}, {0,2448,7586} } },
    ["cathedral debris"] = { name = "Cathedral debris", site = "Senntisten", coords = { {0,1771,1275}, {0,1777,1271}, {0,1770,1268} } },
    ["cauldron debris"] = { name = "Cauldron debris", site = "Moonrise", coords = { {1,3751,8036}, {1,3757,8034}, {1,3759,8038} } },
    ["centurion remains"] = { name = "Centurion remains", site = "Archaeology Campus", coords = { {0,3388,3394} } },
    ["ceramics studio debris"] = { name = "Ceramics studio debris", site = "Everlight", coords = { {0,3737,3275}, {0,3741,3276}, {0,3737,3279} } },
    ["chthonian trophies"] = { name = "Chthonian trophies", site = "Infernal Source", coords = { {1,2620,7441}, {1,2614,7445}, {1,2607,7444}, {1,2609,7439}, {1,2615,7439} } },
    ["citizen remains"] = { name = "Citizen remains", site = "Senntisten", coords = { {0,1798,1289}, {0,1793,1284}, {0,1799,1283} } },
    ["communal space"] = { name = "Communal space", site = "Daemonheim", coords = { {1,3463,3733}, {1,3465,3728}, {1,3467,3732} } },
    ["crucible stands debris"] = { name = "Crucible stands debris", site = "Warforge", coords = { {0,2415,7319}, {0,2418,7319}, {0,2419,7322}, {0,2385,7320}, {0,2382,7320}, {0,2383,7317} } },
    ["crystallised rubble"] = { name = "Crystallised rubble", site = "Orthen", coords = { {0,3932,9845} } },
    ["culinarum debris"] = { name = "Culinarum debris", site = "Kharid-et", coords = { {0,2488,7586}, {0,2482,7586}, {0,2481,7591} } },
    ["cultist footlocker"] = { name = "Cultist footlocker", site = "Infernal Source", coords = { {0,2671,7305}, {0,2672,7309}, {0,2673,7311}, {0,2674,7303}, {0,2676,7306}, {0,2676,7309} } },
    ["destroyed golem"] = { name = "Destroyed golem", site = "Stormguard Citadel", coords = { {1,2404,7123}, {1,2400,7118}, {1,2396,7125}, {1,2399,7130}, {1,2404,7130} } },
    ["dis dungeon debris"] = { name = "Dis dungeon debris", site = "Infernal Source", coords = { {0,2655,7307}, {0,2658,7301}, {0,2661,7304} } },
    ["dis overspill"] = { name = "Dis overspill", site = "Infernal Source", coords = { {2,2644,7399}, {2,2641,7401}, {2,2635,7397}, {2,2637,7391} } },
    ["dominion games podium"] = { name = "Dominion Games podium", site = "Everlight", coords = { {0,3795,3227}, {0,3798,3231}, {0,3793,3234} } },
    ["dragonkin coffin"] = { name = "Dragonkin coffin", site = "Orthen", coords = { {2,1122,149}, {2,1123,144}, {2,1125,140}, {2,1127,135}, {2,1128,151} } },
    ["dragonkin reliquary"] = { name = "Dragonkin reliquary", site = "Orthen", coords = { {2,1126,123}, {2,1127,120}, {2,1126,117} } },
    ["dragonkin remains"] = { name = "Dragonkin remains", site = "Orthen", coords = { {1,5526,2836}, {1,5526,2843}, {0,3883,4312} } },
    ["experiment workbench"] = { name = "Experiment workbench", site = "Orthen", coords = { {0,1261,106}, {0,1262,100}, {0,1258,94}, {0,1255,88} } },
    ["flight research debris"] = { name = "Flight research debris", site = "Stormguard Citadel", coords = { {1,2467,7128}, {1,2471,7126}, {1,2479,7126}, {1,2480,7122}, {1,2482,7133} } },
    ["fort debris"] = { name = "Fort debris", site = "Kharid-et", coords = { {0,3373,3178} } },
    ["forum entrance"] = { name = "Forum entrance", site = "Senntisten", coords = { {0,735,375} } },
    ["gladiator remains"] = { name = "Gladiator remains", site = "Senntisten", coords = { {0,358,149}, {0,360,146}, {0,363,150} } },
    ["gladiatorial goblin remains"] = { name = "Gladiatorial goblin remains", site = "Warforge", coords = { {0,2395,7318}, {0,2402,7318}, {0,2398,7311} } },
    ["goblin dorm debris"] = { name = "Goblin dorm debris", site = "Warforge", coords = { {0,2312,7330}, {0,2313,7326}, {0,2315,7327} } },
    ["goblin trainee remains"] = { name = "Goblin trainee remains", site = "Warforge", coords = { {0,2304,7406}, {0,2299,7409}, {0,2294,7409}, {0,2297,7403}, {0,2288,7409} } },
    ["gravitron research debris"] = { name = "Gravitron research debris", site = "Stormguard Citadel", coords = { {1,2387,7188}, {1,2384,7183}, {1,2385,7178}, {1,2391,7175}, {1,2394,7181} } },
    ["hellfire forge"] = { name = "Hellfire forge", site = "Infernal Source", coords = { {2,2645,7446}, {2,2639,7449}, {2,2645,7454} } },
    ["howl workshop debris"] = { name = "Howl's workshop debris", site = "Stormguard Citadel", coords = { {3,2415,7155}, {3,2416,7161}, {3,2410,7157}, {3,2405,7161} } },
    ["icyene weapon rack"] = { name = "Icyene weapon rack", site = "Everlight", coords = { {0,3801,3217}, {0,3806,3221}, {0,3796,3213} } },
    ["ikovian memorial"] = { name = "Ikovian memorial", site = "Stormguard Citadel", coords = { {0,2673,3395}, {0,2676,3401}, {0,2682,3397}, {1,2450,7164}, {1,2454,7163}, {1,2459,7164}, {1,2458,7173}, {1,2461,7169} } },
    ["infernal art"] = { name = "Infernal art", site = "Infernal Source", coords = { {3,2633,7383}, {3,2638,7379}, {3,2642,7386}, {3,2646,7383}, {3,2586,7392}, {3,2592,7387}, {3,2594,7392}, {3,2598,7389} } },
    ["inquisitor remains"] = { name = "Inquisitor remains", site = "Senntisten", coords = { {0,1696,1344}, {0,1692,1342}, {0,1699,1340} } },
    ["keshik ger"] = { name = "Keshik ger", site = "Stormguard Citadel", coords = { {1,2470,7199}, {1,2471,7205}, {1,2482,7208}, {1,2486,7207}, {1,2478,7213} } },
    ["keshik tower debris"] = { name = "Keshik tower debris", site = "Stormguard Citadel", coords = { {1,2538,7131}, {1,2534,7136}, {1,2540,7135} } },
    ["keshik weapon rack"] = { name = "Keshik weapon rack", site = "Stormguard Citadel", coords = { {1,2335,7258}, {1,2332,7255}, {1,2331,7252}, {1,2332,7247}, {1,2336,7244} } },
    ["kharid-et chapel debris"] = { name = "Kharid-et chapel debris", site = "Kharid-et", coords = { {0,2479,7575}, {0,2484,7579}, {0,2487,7577} } },
    ["kyzaj champion boudoir"] = { name = "Kyzaj champion's boudoir", site = "Warforge", coords = { {0,2303,7321}, {0,2307,7313}, {0,2310,7320}, {0,2306,7318} } },
    ["legionary remains"] = { name = "Legionary remains", site = "Kharid-et", coords = { {0,2436,7595}, {0,2438,7594}, {0,2438,7600} } },
    ["lodge art storage"] = { name = "Lodge art storage", site = "Infernal Source", coords = { {0,2591,7335}, {0,2597,7336}, {0,2599,7331} } },
    ["lodge bar storage"] = { name = "Lodge bar storage", site = "Infernal Source", coords = { {0,2590,7326}, {0,2594,7320}, {0,2596,7325} } },
    ["lunar wheel debris"] = { name = "Lunar wheel debris", site = "Moonrise", coords = { {0,4439,3435}, {0,4442,3426}, {0,4450,3432} } },
    ["makeshift pie oven"] = { name = "Makeshift pie oven", site = "Warforge", coords = { {0,2301,7370}, {0,2302,7365}, {0,2301,7368}, {0,2303,7363} } },
    ["marketplace debris"] = { name = "Marketplace debris", site = "Senntisten", coords = { {0,1672,1327}, {0,1667,1325}, {0,1668,1321} } },
    ["ministry remains"] = { name = "Ministry remains", site = "Senntisten", coords = { {0,1746,1245}, {0,1741,1244}, {0,1745,1241} } },
    ["moksha device"] = { name = "Moksha device", site = "Orthen", coords = { {1,1123,227}, {1,1123,219}, {1,1115,227}, {1,1115,219} } },
    ["monoceros remains"] = { name = "Monoceros remains", site = "Everlight", coords = { {0,3743,3200}, {0,3746,3202}, {0,3748,3205} } },
    ["mystery remains"] = { name = "Mystery remains", site = "Harvest Hollow", coords = { {0,572,1742}, {0,573,1746}, {0,575,1736}, {0,577,1739} } },
    ["oikos fishing hut remnants"] = { name = "Oikos fishing hut remnants", site = "Everlight", coords = { {0,3726,3164}, {0,3727,3172}, {0,3731,3170} } },
    ["oikos studio debris"] = { name = "Oikos studio debris", site = "Everlight", coords = { {0,3739,3176}, {0,3738,3179}, {0,3742,3178} } },
    ["optimatoi remains"] = { name = "Optimatoi remains", site = "Everlight", coords = { {1,2328,7527}, {1,2332,7534}, {1,2329,7535} } },
    ["orcus altar"] = { name = "Orcus altar", site = "Kharid-et", coords = { {0,2488,7570}, {0,2490,7567}, {0,2491,7572} } },
    ["orthen rubble"] = { name = "Orthen rubble", site = "Orthen", coords = { {1,5541,2840}, {1,5543,2843}, {0,3882,4322} } },
    ["pontifex remains"] = { name = "Pontifex remains", site = "Kharid-et", coords = { {0,2482,7565}, {0,2483,7571}, {0,2485,7566} } },
    ["praesidio remains"] = { name = "Praesidio remains", site = "Kharid-et", coords = { {0,2254,7597}, {0,2255,7599}, {0,2258,7594} } },
    ["praetorian remains"] = { name = "Praetorian remains", site = "Kharid-et", coords = { {0,2651,7569}, {0,2656,7572}, {0,2659,7570} } },
    ["prodromoi remains"] = { name = "Prodromoi remains", site = "Everlight", coords = { {0,3727,3232}, {0,3733,3231}, {0,3736,3225}, {0,3766,3215}, {0,3768,3210}, {0,3772,3216} } },
    ["projection space"] = { name = "Projection space", site = "Daemonheim", coords = { {1,2193,9241}, {1,2195,9237}, {1,2197,9243} } },
    ["runic debris"] = { name = "Runic debris", site = "Memorial to Guthix", coords = { {0,2289,3537} } },
    ["sacrificial altar"] = { name = "Sacrificial altar", site = "Infernal Source", coords = { {0,2634,7333}, {0,2637,7330}, {0,2640,7331} } },
    ["saurthen debris"] = { name = "Saurthen debris", site = "Orthen", coords = { {0,1246,230}, {0,1250,226}, {0,1246,222}, {0,1247,215}, {0,1251,211}, {0,1256,210} } },
    ["security booth"] = { name = "Security booth", site = "Daemonheim", coords = { {1,2221,9257}, {1,2224,9253}, {1,2224,9258} } },
    ["shakroth remains"] = { name = "Shakroth remains", site = "Infernal Source", coords = { {3,2606,7464}, {3,2612,7464}, {3,2618,7468}, {3,2655,7452}, {3,2661,7452}, {3,2665,7449} } },
    ["shrine debris"] = { name = "Shrine debris", site = "Moonrise", coords = { {0,4433,3452}, {0,4436,3444}, {0,4442,3448} } },
    ["stadio debris"] = { name = "Stadio debris", site = "Everlight", coords = { {0,3815,3177}, {0,3818,3181}, {0,3819,3174} } },
    ["standing stone debris"] = { name = "Standing stone debris", site = "Memorial to Guthix", coords = { {0,2280,3541} } },
    ["stockpiled art"] = { name = "Stockpiled art", site = "Everlight", coords = { {1,2341,7515}, {1,2335,7523}, {1,2330,7525} } },
    ["tailory debris"] = { name = "Tailory debris", site = "Stormguard Citadel", coords = { {1,2505,7190}, {1,2509,7189}, {1,2503,7188}, {1,2504,7184}, {1,2508,7181} } },
    ["traveller station"] = { name = "Traveller's station", site = "Daemonheim", coords = { {1,2195,9261}, {1,2195,9265}, {1,2199,9264} } },
    ["tsutsaroth remains"] = { name = "Tsutsaroth remains", site = "Infernal Source", coords = { {1,2601,7415}, {1,2607,7414}, {1,2604,7408}, {1,2610,7405} } },
    ["tunnelling equipment repository"] = { name = "Tunnelling equipment repository", site = "Daemonheim", coords = { {0,3447,3743}, {0,3452,3742}, {0,3455,3746} } },
    ["varanusaur remains"] = { name = "Varanusaur remains", site = "Orthen", coords = { {2,1107,144}, {2,1115,144}, {2,1113,140} } },
    ["venator remains"] = { name = "Venator remains", site = "Kharid-et", coords = { {0,3371,3193}, {0,3370,3189}, {0,3376,3188} } },
    ["war table debris"] = { name = "War table debris", site = "Kharid-et", coords = { {0,2653,7580}, {0,2657,7579}, {0,2650,7584} } },
    ["warforge scrap pile"] = { name = "Warforge scrap pile", site = "Warforge", coords = { {0,2286,7394}, {0,2284,7392}, {0,2287,7391} } },
    ["warforge weapon rack"] = { name = "Warforge weapon rack", site = "Warforge", coords = { {0,2290,7365}, {0,2291,7363}, {0,2290,7360} } },
    ["weapons research debris"] = { name = "Weapons research debris", site = "Stormguard Citadel", coords = { {1,2399,7213}, {1,2402,7204}, {1,2405,7212}, {1,2407,7205}, {1,2409,7212} } },
    ["weaver hut debris"] = { name = "Weaver's hut debris", site = "Moonrise", coords = { {0,4417,3428}, {0,4423,3425}, {0,4429,3428} } },
    ["xolo mine"] = { name = "Xolo mine", site = "Orthen", coords = { {0,1258,226}, {0,1254,225}, {0,1255,221} } },
    ["xolo remains"] = { name = "Xolo remains", site = "Orthen", coords = { {0,1241,213}, {0,1244,211}, {0,1242,208} } },
    ["yu'biusk animal pen"] = { name = "Yu'biusk animal pen", site = "Warforge", coords = { {0,2293,7338}, {0,2295,7331}, {0,2287,7337} } },
}

-- Lowercase material name -> { {level, x, z}, ... } for Material Caches
Locations.CACHES = {
    ["aetherium alloy"] = { {1,2455,7256}, {1,2471,7265}, {1,2393,7213}, {1,2412,7202}, {1,3806,4387}, {1,3808,4390}, {1,3815,4386} },
    ["ancient vis"] = { {0,2488,7596}, {0,2494,7591}, {2,3399,3563}, {2,3400,3555}, {2,3405,3566}, {2,3405,3551} },
    ["animal furs"] = { {0,2518,2903}, {0,2519,2905}, {0,2521,2901}, {0,2518,2901} },
    ["armadylean yellow"] = { {1,2487,7221}, {1,2491,7214}, {1,2492,7188}, {1,2507,7176}, {1,2519,7173}, {1,3793,4392}, {1,3797,4390}, {1,3800,4388} },
    ["banded limestone"] = { {0,4461,3419}, {0,4463,3411} },
    ["blood of orcus"] = { {0,2491,7565}, {0,2497,7568}, {2,3399,3558}, {2,3405,3556}, {2,3405,3562} },
    ["burnt umber"] = { {1,3730,8020}, {1,3742,8039}, {1,3746,8044} },
    ["cadmium red"] = { {0,2589,7316}, {0,2595,7315}, {1,2611,7410}, {1,2618,7406}, {0,1686,6108}, {0,1690,6104}, {0,1691,6110} },
    ["carbon black"] = { {1,1102,239}, {1,1106,236}, {1,4779,6039}, {1,4774,6035}, {1,4782,6032} },
    ["cashmere"] = { {0,4313,3474}, {0,4319,3468}, {0,4321,3476} },
    ["chaotic brimstone"] = { {3,2635,7377}, {3,2641,7379}, {0,3407,3653}, {0,3411,3656}, {0,3415,3650} },
    ["cobalt blue"] = { {0,3727,3270}, {0,3732,3276}, {0,2905,5290}, {0,2908,5292}, {0,2902,5292} },
    ["compass rose"] = { {1,1738,5310}, {1,1740,5309}, {1,1744,5311}, {1,1745,5305}, {2,1111,152}, {2,1116,149} },
    ["demonhide"] = { {2,2608,7450}, {2,2623,7460}, {2,2604,7455}, {0,2931,5359}, {0,2934,5346}, {0,2937,5350}, {0,2926,5359} },
    ["dragon metal"] = { {1,1746,5302}, {1,1751,5304}, {1,1753,5301}, {0,1239,107}, {0,1246,105}, {0,1241,245} },
    ["everlight silvthril"] = { {0,3813,3199}, {0,3817,3195}, {0,3551,3267}, {0,3554,3272}, {0,3549,3268} },
    ["eye of dagon"] = { {0,2669,7307}, {0,2678,7311}, {0,3408,3655}, {0,3410,3653}, {0,3416,3657} },
    ["felt"] = { {0,3761,4143}, {0,3764,4146}, {0,3765,4150}, {0,3773,4145}, {2,1116,136}, {2,1118,140}, {0,1231,92}, {0,1235,87} },
    ["fossilised bone"] = { {1,1743,5307}, {1,1748,5310}, {1,1749,5307}, {0,3367,3505}, {0,3367,3506}, {0,3368,3502}, {0,4323,3421}, {0,4321,3415}, {0,4330,3415} },
    ["goldrune"] = { {0,3034,9883}, {0,3033,9881}, {0,3040,9878}, {0,3039,9885} },
    ["hellfire metal"] = { {0,2666,7347}, {0,2676,7343}, {3,2636,7463}, {3,2649,7466}, {1,2645,7429}, {0,2884,5361}, {0,2887,5365}, {0,2901,5365}, {0,2904,5366}, {0,2906,5364} },
    ["imperial steel"] = { {0,2442,7601}, {0,2452,7610}, {2,2855,12651}, {2,2865,12656}, {2,2865,12652}, {2,2863,12649} },
    ["ivory"] = { {0,4331,3425}, {0,4336,3419}, {0,4339,3427} },
    ["keramos"] = { {0,3721,3236}, {0,3729,3245}, {0,3742,3242}, {0,3725,3177}, {0,3726,3186}, {0,2900,5283}, {0,2903,5284}, {0,2902,5282} },
    ["leather scraps"] = { {0,3440,3530}, {0,3438,3530}, {0,3441,3528} },
    ["malachite green"] = { {0,2393,7316}, {0,2410,7321}, {0,2315,7382}, {0,2325,7371}, {0,2827,5316}, {0,2829,5314}, {0,2832,5316} },
    ["mark of the kyzaj"] = { {0,2284,7414}, {0,2320,7409}, {0,2848,5313}, {0,2850,5316}, {0,2851,5320} },
    ["orgone"] = { {0,3769,4177}, {0,3774,4179}, {0,3778,4176}, {1,1133,206}, {1,1137,212}, {0,1251,238}, {0,1258,235} },
    ["orthenglass"] = { {0,3905,4420}, {0,3906,4423}, {0,3907,4418}, {0,3911,4421} },
    ["quintessence"] = { {3,2400,7167}, {3,2426,7153}, {3,2427,7150}, {1,2468,7254}, {1,2474,7263}, {1,3795,4376}, {1,3798,4378}, {1,3801,4379} },
    ["samite silk"] = { {0,3369,3201}, {0,3372,3200}, {0,3377,3198}, {0,3379,3197}, {2,3339,3144}, {2,3341,3146}, {2,3344,3142}, {2,3346,3145} },
    ["soapstone"] = { {0,3882,1961}, {0,3883,1957}, {0,3885,1959}, {0,3885,1955} },
    ["star of saradomin"] = { {0,3767,3140}, {0,3767,3153}, {0,3551,3273}, {0,3556,3265}, {0,3557,3270} },
    ["stormguard steel"] = { {1,2383,7126}, {1,2386,7119}, {1,2396,7129}, {0,2849,5290}, {0,2854,5287}, {0,2852,5289}, {0,2856,5283} },
    ["third age iron"] = { {0,3386,3400}, {0,3389,3397}, {0,3389,3402} },
    ["triskelion"] = { {0,4327,3466}, {0,4332,3471}, {0,4333,3467} },
    ["tyrian purple"] = { {0,2471,7595}, {0,2472,7588}, {2,2864,12617}, {2,2864,12624}, {2,2859,12623}, {2,2856,12624} },
    ["vellum"] = { {0,1699,6115}, {0,1702,6114}, {0,1705,6116} },
    ["vulcanised rubber"] = { {0,2304,7311}, {0,2308,7329}, {0,2312,7320}, {0,2331,7334}, {0,2383,2822}, {0,2386,2828}, {0,2387,2824} },
    ["warforged bronze"] = { {0,2400,7311}, {0,2409,7319}, {0,2287,7396}, {0,2313,7392}, {0,2864,5344}, {0,2871,5347}, {0,2868,5346}, {0,2827,5318}, {0,2833,5320}, {0,2845,5319}, {0,2842,5317} },
    ["white marble"] = { {0,3815,3207}, {0,3818,3206}, {0,3704,3166}, {0,3707,3163}, {0,1699,6109}, {0,1700,6104}, {0,1702,6109} },
    ["white oak"] = { {0,3006,3497}, {0,3008,3499}, {0,3009,3497} },
    ["wings of war"] = { {1,2346,7249}, {1,2355,7256}, {1,2551,7137}, {1,2552,7127}, {0,2846,5297}, {0,2848,5301}, {0,2855,5297}, {0,2858,5292} },
    ["yu'biusk clay"] = { {0,2284,7337}, {0,2291,7330}, {0,2391,2820}, {0,2393,2817}, {0,2395,2829}, {0,2398,2826} },
    ["zarosian insignia"] = { {0,2430,7601}, {0,2436,7599}, {2,2872,12646}, {2,2875,12644}, {2,2873,12631}, {2,2876,12631} },
}

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
