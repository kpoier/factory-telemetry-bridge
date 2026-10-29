# Factory Telemetry Bridge API

This documents the existing Lua implementation packaged for the first public release, 0.6.0. The internal mod name remains `factory-telemetry-bridge`; consumers and saves must continue to use that name. Factorio 2.1.23 or later in the 2.1 series is required by the current metadata.

## Execution and access

All multiplayer peers must have the same mod version. “Server console only” means the command rejects an invocation with a `player_index`; it does **not** mean its Lua calculations run exclusively on the server. Multiplayer clients still execute synchronized simulation scripts. File and UDP publication use Factorio's server target (`0`). Adding this mod does not offload client simulation.

The mod does not contain an HTTP server, website, RCON client, authentication service, historical database or AI integration. A separate trusted consumer must read the output file or connect to the game's configured RCON endpoint. Protect that endpoint and any published output: responses can include player names and positions, administrator status, AFK/online ticks, map seed, factory layout and installed mod names.

Most commands below are intended for an already authenticated RCON session. Do not prepend `/silent-command` or `/sc`; these are registered commands, not arbitrary Lua. The examples are the literal command text sent as the RCON request body. An in-game player typing the same command is rejected, including administrators, except for the two explicitly listed administrator commands.

Some pause UI, notices and error strings remain hardcoded in Traditional Chinese. The English and Traditional Chinese locale files currently cover mod settings, not every UI string.

## Settings and automatic publication

All five settings are runtime-global settings shared by the world.

| Setting | Default | Behavior |
| --- | --- | --- |
| `ftb-transport` | `file` | `file` or `udp`; attempts UDP and falls back to file if the API call raises an error. UDP delivery is not acknowledged. |
| `ftb-udp-port` | `34198` | Integer, 1024–65535; receiving application is configured separately. |
| `ftb-watch-items` | `ash,iron-plate,copper-plate,steel-plate,coal,stone,stone-brick` | Comma/whitespace-separated item prototype names; known names remain visible even without production history. |
| `ftb-force` | `player` | Internal force name, which must exist. |
| `ftb-surface` | `nauvis` | Internal surface name, which must exist. |

A snapshot is collected every **300 game ticks**. That is five seconds at 60 UPS, with publication delayed or stopped when simulation slows or pauses. The file is overwritten at `<Factorio write-data>/script-output/factory-telemetry-bridge/state.json`. The implementation computes a full snapshot on a single tick; this release has not spread that work across ticks. Large worlds can experience periodic script-time spikes.

Production, power, research and map queries use the selected force/surface. Connected-player output contains all connected players, including those on other surfaces or forces. A missing configured force/surface causes queries to raise an error; configure valid names before polling.

## RCON commands

Numbers are decimal integers unless stated otherwise. Chunk coordinates use 32×32 tiles. Optional arguments are shown in square brackets only in this table; do not send the brackets.

| Command | Request and response |
| --- | --- |
| `/ftb-snapshot` | Current telemetry snapshot. |
| `/ftb-map [cursor [limit [expected_revision]]]` | Page of charted chunk geometry. Cursor defaults to 0, limit to 8 and is clamped to 1–16. Start a sweep at cursor 0; reuse returned `next_cursor` and `revision`. A revision mismatch resets the cursor. Starting a sweep rebuilds the charted-chunk index. |
| `/ftb-index` | Rebuild and return all charted chunk coordinates, spawn and identity. This is not a bounded/paged response. |
| `/ftb-changes [since]` | Changed-chunk journal after the supplied revision (default 0). The journal retains 4096 entries. `reset: true` requires a fresh index/full synchronization; load/reload also clears the in-memory journal. |
| `/ftb-view detail x y [x y ...]` | One to eight requested chunks; `detail` is 0 or 1. Only charted chunks are returned. Chunk coordinates must be within ±62500. Detailed output includes connections, fluids and bounds. |
| `/ftb-chart x y` | One chunk's native chart pixels encoded as hexadecimal, or absent pixel fields if unavailable. Chunk coordinates must be within ±62500. |
| `/ftb-charts x y [x y ...]` | One to eight chart tiles with a response-level `profile` string. |
| `/ftb-export kind cursor limit` | Context export: kind 0 = metadata, 1 = recipes, 2 = placeable entity prototypes, 3 = technologies. Kinds 1–3 use limit 1–64; start cursor 0 and continue with returned `next_cursor` until `done`. Kind 0 returns metadata and ignores pagination. |
| `/ftb-export-area left top right bottom` | Existing-world observations and a native blueprint for a charted rectangle. Right/bottom are exclusive. See limits below. |
| `/ftb-pause {"paused":true,"actor":"Operator"}` | Change script pause state; `paused` must be boolean and `actor` a string up to 384 bytes. The actor is a caller-supplied label, not an authenticated player identity. Returns pause state and action metadata; emits an in-game notice. |
| `/ftb-save` | Request `game.server_save()`; returns `requested: true`. This acknowledges the request, not completed disk persistence. |
| `/ftb-profile` | Collect a snapshot under a Factorio profiler and return its formatted duration. This measures this query only, not total engine update time. |
| `/ftb-end` | Return literal `FTB_END`, for consumers delimiting multiple RCON responses. |
| `/ftb-resume` | Resume script pause. Also available to an in-game administrator. |
| `/ftb-admin-pause` | Pause simulation. Also available to an in-game administrator. |

The interface includes administrative writes; it is not wholly read-only. Telemetry and export commands do not place buildings or modify recipes. Snapshot queries also synchronize the pause notice GUI. Blueprint export creates and destroys a temporary script inventory.

Example RCON request bodies:

```text
/ftb-snapshot
/ftb-map 0 8
/ftb-map 8 8 1
/ftb-index
/ftb-changes 0
/ftb-view 1 0 0 1 0
/ftb-chart 0 0
/ftb-charts 0 0 1 0
/ftb-export 0 0 64
/ftb-export 1 0 64
/ftb-export-area 0 0 32 32
/ftb-profile
/ftb-end
```

The `8` and `1` in `/ftb-map 8 8 1` are illustrative: replace cursor and revision with the previous response's `next_cursor` and `revision`. Area/chart requests require that the chosen coordinates are charted for the selected force. Administrative examples, to execute only when an actual state change is intended:

```text
/ftb-pause {"paused":true,"actor":"Operator"}
/ftb-resume
/ftb-save
```

Invalid parameters and unavailable context can raise Factorio command errors rather than a JSON error object. Export-area refusal for uncharted chunks or excessive entities instead returns a result containing `error`. Consumers must handle both forms.

## Response schemas

Most structured responses use JSON `schema_version: 2`. Additive fields may occur; consumers should tolerate them. Lua `nil` fields can be absent from JSON, and empty Lua tables should not be assumed to encode a particular array/object shape. Numeric entity and network identifiers are observational identifiers, not stable names across world edits.

A snapshot contains:

- Identity/time: `schema_version`, `mod_version`, `world_id`, `tick`, `tick_paused`, `speed`, `force`, `surface`, `seed`.
- `players`: index/name, x/y, surface/force, color, `afk_ticks`, `online_ticks`, administrator flag.
- `items` / `fluids`: internal name, kind, `produced_per_min`, `consumed_per_min`, `net_per_min` and watched flag. These use Factorio's one-minute flow precision; `sample_window_seconds` is 60.
- `power`: production/consumption MW, networks, network count, scanned/total chunk counts and coverage description.
- Optional current `research`, `trains`, `train_limit`, `tags`, `tag_limit`, `spawn`, optional `pause_info` / `last_pause_action`.

`world_id` is initialized from map seed and game tick when the mod first initializes in a save; it is not a cryptographically unique identity and is not regenerated for every branch/copy of that save. Do not use it as an authentication secret or the sole proof of save identity.

Map pages include `revision`, `tick`, `total`, `cursor`, `next_cursor`, `done`, `chunks`, and force/surface/seed. Each chunk reports x/y, entities, summarized resources, wires, pipes, `detailed`, `truncated`, and tick. Detailed connections come from the game APIs; they are not inferred merely from distance. Chart-tile responses include x/y, optional `pixels` and `bytes`, plus identity/time. Some commands append a human-readable `profile` field via Factorio's localized-string formatting; do not treat it as a stable numeric duration format.

Catalog pages include identity/time, `entries`, `total`, `next_cursor`, and `done`. Metadata includes researched technologies, enabled recipes, research queue, direction constants, pause/speed and optional current research. Entity prototype specifications refer to **normal quality**; live area observations separately include actual quality and effective crafting speed where available.

Area exports include bounds, observed entities/inventories/fluids, `blueprint_string`, `blueprint_entities`, `blueprint_world_positions`, terrain run lengths/prototypes, neutral obstacles, truncation marker and summarized resources. Blueprints can include ghosts even though the live observation list omits entity/tile ghosts. Fluid quantities and segment IDs are not instantaneous throughput measurements. A caller combining pages receives multiple observation ticks, not an atomic whole-world snapshot.

## Coverage, limits and cost

- Power coverage depends on electric poles cached by prior map/view scans. It may be empty/incomplete before scanning; uncharted networks are excluded. Use the returned coverage counters and do not interpret every zero as a measured whole-world zero.
- Train output scans at most 128 **locomotives**, then deduplicates trains. It does not guarantee 128 distinct trains. Chart tags are capped at 200.
- Chunk geometry examines at most 4096 matching entities and retains at most 8192 wire and 8192 pipe records; `truncated` signals limits. The journal can contain duplicate chunk coordinates. Consumers may deduplicate them.
- Area rectangles must have positive dimensions, be no larger than 256×256 tiles, use coordinates within ±1999999, and be fully charted. More than 4096 selected-force entities causes refusal. Neutral obstacles are capped at 512 with `obstacles_truncated`; resources are summarized. Large requests can still be expensive inside one simulation tick.
- The charted-chunk index and metadata/catalog responses can be large. There is no rate limiter in the mod. Bound polling and spread expensive requests across time in the external consumer.
- Runtime caches and the changes journal are ephemeral and reset on Lua-state reload. Consumers must be able to restart synchronization rather than relying on revisions surviving reloads.
- Script pause controlled here is distinct from the game's empty-server automatic pause or native multiplayer menu behavior. `tick_paused` alone does not describe all reasons the multiplayer server may currently be idle.

## Lua remote interface

Other mods can call `remote.call("factory_telemetry", function_name, ...)` with these functions:

| Function | Arguments | Result |
| --- | --- | --- |
| `snapshot` | none | Snapshot Lua table, not pre-encoded JSON. |
| `map_batch` | cursor, limit, optional expected revision | Map page Lua table, same limits as `/ftb-map`. |
| `validation_probe` | none | Compatibility self-check result; throws on a failed assertion. |

`validation_probe` is a maintenance interface intended for a **private copy of a save**. It enumerates catalogs and exercises snapshots, charted chunks, fluid entities, area exports and profiling. It can be expensive and must not be used as a high-frequency health check. It is not an RCON command and no `/ftb-validation-probe` command is registered.
