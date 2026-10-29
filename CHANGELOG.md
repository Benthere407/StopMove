# StopMove changelog

## 2.0

### Added
- **In-game auto-follow (`/follow`) option** (Settings > Casting actions). When a cast starts, the game's own auto-follow is stopped. When the cast is over (after the unlock wait), it starts again on the same target. Plain auto-run is stopped but not restarted.
- **Follow after cast** name box. Type a character name, and after every cast StopMove makes sure auto-follow is on and following that character (it sends `/follow <name>`), even if you were not following anyone before.
  - Nothing is sent if that character is not in your zone, or if you are already following them.
  - Both clients share this setting; the named character never tries to follow itself.
- **Allow Move button on the widget**, with a checkbox to show or hide it (General > Allow Move button). It ends the cast lock at once and turns orange while either character is locked.
- **`/stopmove move`** command, same as the Allow Move button.
- **Letter inside the shape (smallest)** widget style (General > Low profile widget > Letter inside the shape).
  - One small square or circle per character, with the first letter inside; the colour shows ON / OFF / LOCK.
  - The UI and Allow Move buttons become tiny **U** and **M** badges, with tooltips.
- **Mouse-wheel resizing**: roll the wheel over the widget to make it bigger or smaller (not while Lock box position and size is ticked).
- **Widget size** slider in Settings > Layout (0.3 to 4).

### Changed
- **"Release now" is renamed "Allow Move"**, and it now also:
  - frees the other client's character if that one is locked;
  - sends a fresh key-press for any movement key you are still holding, so you move straight away instead of having to let go and press it again;
  - leaves keyboard focus with the game after you click the widget button.
- In Letter inside the shape mode the widget has **no corner resize triangle**, so it can't cover the badges or block clicks. Use the mouse wheel or the Widget size slider instead. The other styles keep the triangle.
- The widget never takes keyboard input away from the game.
- Turning Multisend follow off in the middle of a cast now sends only the Multisend "on" command; it no longer restarts the in-game follow mid-cast.

### Removed
- **Hold position while casting** (added in 1.8). StopMove no longer reads or rewrites the 0x0015 position packets your client sends; your real position always goes to the server unchanged.
  - Key blocking, Release held movement keys and Wait until stopped still protect the cast.
  - If you cast while following, a Spell cast delay of 0.25 to 0.30 seconds (Settings > Timing) is the safest setting.
  - The old `pin_pos` line in `settings.txt` is ignored.

## 1.9

### Added
- **Hide Multisend follow messages in the chat log** (on by default). Multisend's "Multisend: Follow is currently enabled/disabled." replies to StopMove's own follow commands are hidden. A `/ms follow` you type yourself still shows.

## 1.8

### Added
- Movement keys are also cleared from the keyboard state the game reads each frame while casting, so a held key can't slip through.
- Hold position while casting (removed again in 2.0).
