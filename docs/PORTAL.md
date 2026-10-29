# Factory Telemetry Bridge

A telemetry bridge for Factorio 2.1.23 and later in the 2.1 series. It exports factory statistics, player and research information, bounded charted-map observations, and recipe/equipment/technology data for external tools.

## Getting started

Install the same mod version on the server and every multiplayer client. The default output is JSON at `script-output/factory-telemetry-bridge/state.json` under Factorio's write-data directory, sampled every 300 game ticks. A server console or RCON consumer can also call `/ftb-snapshot`.

The force defaults to `player` and the surface to `nauvis`; both must exist. The mod provides optional UDP output and falls back to a file if UDP cannot be sent.

This package does not include a web dashboard, HTTP service, database, or RCON client. Build or configure an external consumer for those functions.

## Multiplayer and performance

This is not a server-only mod. Output is directed to the server, but the Lua collection runs on multiplayer peers. Polling and detailed exports have a simulation cost; use bounded requests and modest sampling rates. The initial source release preserves the existing collection behavior.

Power statistics cover cached scanned poles in charted chunks and may be incomplete. Production figures use a one-minute statistics window. Map and catalog exports are bounded and not an atomic world snapshot.

## Administrator controls

The mod includes explicit pause/resume and server-save commands in addition to telemetry. Most data commands are limited to the server console/RCON; in-game administrators can use the dedicated pause/resume controls. Existing control messages are partly in Chinese; settings are localized in English and Traditional Chinese.

## Data visibility

Exports include player names, positions, admin status, world seed, and active mods. Decide who may view the output before exposing an external dashboard.

See the source repository for the command reference, setup instructions, provenance, and release workflow.
