# StopMove

An Ashita v4 addon for FFXI. While you cast a spell it blocks your numpad movement keys (and, optionally, W/A/S/D) so you don't walk and interrupt the cast by accident.

<p align="center">
  <img src="docs/images/3.0/vex-party-view-a.png" width="300" alt="StopMove widget, Vex theme">
  <img src="docs/images/3.0/hex-view-b-lock.png" width="300" alt="StopMove widget, Hex link theme, with one character locked">
  <img src="docs/images/3.0/classic-ffxi-menu.png" width="170" alt="StopMove widget, Classic theme">
</p>

- **Follow off while casting.** It turns Multisend follow (`/ms follow off` / `/ms follow on`, both editable) and the game's own auto-follow (`/follow`) off for the length of a cast and back on afterwards.
- **Follow after cast.** You can type a character name, and after every cast your character follows them.
- **Wait until stopped.** If you press a spell while still moving, the cast is held until your character has stopped.
- **Long and interrupted casts.** Long spells such as Stoneskin, Raise and Teleports stay locked for their whole cast time, and the widget blinks a red **INT** when a cast is interrupted.
- **Widget.** A small on-screen widget shows ON / OFF / LOCK for each of your characters and works across two clients.
- **Three themes.** Classic, plus **Vex** and **Hex link** modelled on the YunaUI party lists, each with its own settings, views and letter-only styles. Each character keeps its own look.
- **Settings window** in the VanaCore menu style, with Search, saved setups, and push / copy to the other client.

Version: **3.0**. Tested on a current LandSandBoat (LSB) server running locally.

- [User guide](docs/USER_GUIDE.md) (also as [StopMove_Guide.docx](StopMove_Guide.docx))
- [Changelog](CHANGELOG.md)

<p align="center">
  <img src="docs/images/3.0/settings-appearance.png" width="600" alt="The StopMove settings window, Appearance page">
</p>

## Install

1. Download `stopmove.zip` from the [latest release](https://github.com/Benthere407/StopMove/releases/latest) and unzip it. You get a folder called `stopmove` containing `stopmove.lua`.
2. Copy the whole `stopmove` folder into your Ashita addons folder, so this file exists: `<Ashita folder>\addons\stopmove\stopmove.lua`
3. In game, type `/addon load stopmove`.
4. To load it automatically, add `/addon load stopmove` to your Ashita startup script (usually `<Ashita folder>\scripts\default.txt`).

Running two clients? Install once; both clients share the same Ashita folder. Load it on each client.

Updating? Replace `stopmove.lua` and type `/addon reload stopmove`. Your settings are kept, and the widget starts in the Classic theme with your old look.

## Uninstall

1. In game: `/addon unload stopmove`
2. Remove `/addon load stopmove` from your startup script, if you added it.
3. Delete `<Ashita folder>\addons\stopmove`. This also deletes your saved setups (its `saved` folder), so copy that first if you want to keep them.
4. Optional: delete `<Ashita folder>\config\addons\stopmove` (saved looks, positions and ON/OFF state).

## Using the widget

- Click a character to switch it on or off.
- **Shift + drag** moves the widget; while the settings window is open, any drag moves it.
- Roll the mouse wheel over it to resize it.
- Right-click it to open the settings window.

## Commands

| Command | What it does |
|---|---|
| `/stopmove` | Opens or closes the settings window |
| `/stopmove on` / `/stopmove off` | Turns StopMove on or off for this character |
| `/stopmove move` | Allow Move: ends the cast lock now |
| `/stopmove resetbox` | Puts the widget back at normal size, top-left |

## Notes

- Keyboard only: gamepad and mouse movement are not blocked.
- One plain-text Lua file. No .exe or .dll, no network access, no account details.
- It does not cast, target, heal or fight for you.
- For transparency:
  - With *Wait until stopped* on, it briefly holds your own cast request and re-sends it unchanged.
  - It can send simulated key-release events at cast start, and a key-press after Allow Move, for movement keys you are holding.
  - With *In-game auto-follow* on, it stops and restarts the game's auto-follow or sends `/follow <name>`.
  - It reads each spell's cast time from the game's own spell data.
  - It does not change position packets.
  - All of these can be switched off in the settings window.

## Credits

- Written with Claude (Anthropic), directed and tested by Benthere407.
- The Vex and Hex link theme appearances are modelled on **YunaUI** by **Yunas**.
- The settings window is inspired by the **VanaCore** menus by **Vekien** and **Josh.Xero**.
- Thanks to **Toots** for support in adjusting the cast lock durations for longer spells.
- Built on the Ashita v4 addon API and the Dear ImGui interface that ships with Ashita.
- Multisend (by ThornyFFXI) is supported only through its `/ms follow` command.
- No code from YunaUI, VanaCore or Multisend is included.
