# StopMove

An Ashita v4 addon for FFXI. While you cast a spell it blocks your numpad movement keys (and, optionally, W/A/S/D) so you don't walk and interrupt the cast by accident.

- Optionally turns Multisend follow off for the length of a cast and back on afterwards (`/ms follow off` / `/ms follow on`, both editable).
- **Hold position while casting** (v1.8): small position slips under 1 yalm are not sent to the server during a cast, so a key that slips through for a frame can't interrupt the spell. Real movement still interrupts as normal.
- A small on-screen widget shows an ON/OFF switch for each of your characters, and works across two clients.

Version: **1.8**. Tested on a current LandSandBoat (LSB) server running locally.

## Install

1. Download `stopmove.zip` from this repository and unzip it. You get a folder called `stopmove` containing `stopmove.lua`.
2. Copy the whole `stopmove` folder into your Ashita addons folder, so this file exists: `<Ashita folder>\addons\stopmove\stopmove.lua`
3. In game, type `/addon load stopmove`.
4. To load it automatically, add `/addon load stopmove` to your Ashita startup script (usually `<Ashita folder>\scripts\default.txt`).

Running two clients? Install once; both clients share the same Ashita folder. Load it on each client.

## Uninstall

1. In game: `/addon unload stopmove`
2. Remove `/addon load stopmove` from your startup script, if you added it.
3. Delete `<Ashita folder>\addons\stopmove`.
4. Optional: delete `<Ashita folder>\config\addons\stopmove` (saved look, position and ON/OFF state).

## Commands

| Command | What it does |
|---|---|
| `/stopmove` | Opens or closes the settings window |
| `/stopmove on` / `/stopmove off` | Turns StopMove on or off for this character |
| `/stopmove resetbox` | Puts the widget back at normal size, top-left |

## Notes

- Keyboard only: gamepad and mouse movement are not blocked.
- One plain-text Lua file. No .exe or .dll, no network access, no account details.
- It does not cast, target, move, heal or follow for you.
- For transparency: with *Wait until stopped* on, it briefly holds your own cast request and re-sends it unchanged; it can send simulated key-release events for movement keys you are holding; and with *Hold position while casting* on, it keeps your outgoing position at the cast-start spot for slips under 1 yalm. All three can be switched off in the settings window.

## Credits

Written with Claude (Anthropic), directed and tested by Benthere407. Built on the Ashita v4 addon API and the Dear ImGui interface that ships with Ashita. Multisend (by ThornyFFXI) is supported only through its `/ms follow` command; none of its code is included.
