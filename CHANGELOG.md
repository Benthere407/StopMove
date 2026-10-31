# StopMove changelog

## 3.0

3.0 adds two new widget themes modelled on YunaUI (Vex and Hex link), a redesigned settings window, saved configurations, and better handling of long and interrupted casts.

Thanks to **Yunas** for YunaUI, whose Vex and Hex party lists the new themes are modelled on, and to **Vekien** and **Josh.Xero** for VanaCore, whose menus inspired the new settings window. No code from either is included. Thanks also to **Toots** for support in adjusting the cast lock durations for longer spells.

### Added

#### Widget themes
Settings > Widget > Appearance > Theme picks one of three themes. Each theme keeps its own settings, so switching themes and back loses nothing. **Reset** puts just the current theme back to its defaults.

- **Classic**: the 2.0 widget (square or circle badges, FFXI-menu or solid background, letter-only styles).

  ![Classic, solid](docs/images/3.0/classic-solid.png) ![Classic, FFXI menu](docs/images/3.0/classic-ffxi-menu.png)
- **Vex**: after YunaUI's Vex party list. Names are in capitals, and the ON / OFF tag is green for ON, red for OFF and gold for LOCK.
  - **Party** row style, view A: the ON / OFF tag, then the name plate over a coloured bar. No box or border behind the rows.
    ![Vex Party, view A](docs/images/3.0/vex-party-view-a.png)
  - **Party** row style, view B: the name plate (the name over two slanted bars, with an empty spot at the right) and then the ON / OFF tag.
    ![Vex Party, view B](docs/images/3.0/vex-party-view-b.png)
  - **Menu** row style: rounded cards. Each card's edge fades from pink-red on the left to violet on the right, a violet divider separates the name from a rounded ON / OFF tag, and the edge turns white while locked.
    ![Vex Menu](docs/images/3.0/vex-menu.png)
  - **Letter styles A, B and C** (first letter only). Views A and B flip which side the ON / OFF part is on.

    | A: dark plate, white letter, state bar | B: letter plate + tag | C: letter + dot |
    |---|---|---|
    | ![Vex letter A](docs/images/3.0/vex-letter-a.png) | ![Vex letter B](docs/images/3.0/vex-letter-b.png) | ![Vex letter C](docs/images/3.0/vex-letter-c.png) |
  - **Gold name and edge on LOCK** switch.
- **Hex link**: after YunaUI's Hex party list. Names are in capitals, with a dark plate, gold corner accents and a gold divider.
  - **View A**: the name, a gold divider, then a job-box style ON / OFF tag.
    ![Hex link, view A](docs/images/3.0/hex-view-a.png)
  - **View B**: the ON / OFF tag (upright on the left, slanted on the right), then the name over a pointed HP-style bar, and an empty box at the right.
    ![Hex link, view B](docs/images/3.0/hex-view-b.png)
  - **Letter styles A, B and C**, with the same view flip as Vex.

    | A: letter in the tag | B: tag + letter | C: dot + letter |
    |---|---|---|
    | ![Hex letter A](docs/images/3.0/hex-letter-a.png) | ![Hex letter B](docs/images/3.0/hex-letter-b.png) | ![Hex letter C](docs/images/3.0/hex-letter-c.png) |
  - LOCK during a cast:
    ![Hex link, view B, locked](docs/images/3.0/hex-view-b-lock.png)
  - **Gold corner accents** switch and **Corner cut** (Small, Medium or Large).
- Settings for both Vex and Hex link:
  - **Align**: left or right.
  - **Size**: Overall length, Name box length and height, ON / OFF box length and height, and the gap between them (down to touching). Names shorten to fit the name box ("BENTHE."), so a longer box shows more of the name.

    ![Hex link, short names](docs/images/3.0/hex-short-names.png) ![Vex, short names](docs/images/3.0/vex-short-names.png)
  - **Name box opacity**, background colour and opacity, ON / OFF / LOCK colours, and **Automatic tag text colour**.

#### Settings window
- **Redesigned** in the Vanacore menu style: a sidebar with icons and a **Search** box, and the pages **About**, **General**, **Casting**, **Follow**, **Timing** and **Widget > Appearance**.
- Each section has a small reset icon that puts just that section back to its defaults.
- **Tools** in the sidebar:
  - **Save and load**: saves the current setup under a name, with the character's name added to the front ("Benthere - my setup"), and loads any saved setup from a dropdown. Setups are plain text files in the `saved` folder next to the addon (`<Ashita folder>\addons\stopmove\saved\`).
  - **Test lock**: shows LOCK on your widget for 3 seconds.
  - **Reset all**: asks first, in a warning window ("This will revert ALL settings to addon defaults.").
- **Push to the other client** (Save and load page): sends a saved setup, or the settings in use now, to the other client. Pushing takes two clicks: the first turns the button red ("Click again to push"), and a second click within 4 seconds sends it. That client first saves what it had (as "before push" plus the date and time), then loads what you pushed.
- **Copy theme to the other client** (Appearance page): sends just the current theme's look.

![The Appearance page](docs/images/3.0/settings-appearance.png)

![The Save and load page](docs/images/3.0/settings-save-load.png)

![The Reset all warning](docs/images/3.0/reset-all-warning.png)

#### Casting
- **INT on the widget**: when a cast is interrupted, the badge blinks a red **INT** for 2 seconds instead of going straight back to ON. The other client's widget shows it too. Interrupts include being hit, stunned, silenced, knocked back, paralyzed or intimidated, or the target dying.
- **Long casts are covered automatically**: StopMove reads each spell's cast time from the game's data, and the Max cast lock safety timer never ends before that cast time plus 2 seconds. Stoneskin (7 s), Raise (15 s) and Teleports (20 s) stay locked until the server says they finished.

#### Widget
- **Shift + drag** moves the widget at any time. While the settings window is open, any drag moves it, even at the smallest size.

### Changed
- **Appearance is per character**: each character keeps its own theme and look (in `look_<name>.txt`). Only the gameplay settings (casting, follow and timing) are shared between the two clients.
- **Paralyzed and intimidated casts count as interrupted**: the server reports these as finished, so before 3.0 follow came straight back. Now the *cast interrupted* unlock wait applies.
- **Max cast lock** now defaults to **9 seconds** (it was 6). Saved settings keep their own value; reset the Timing page's lock section to get 9.
- The ON / OFF text in Vex and Hex link has no drop shadow on bright tags, so it no longer looks bold.

### Removed
- The **UI** and **Allow Move** buttons on the widget, and their options. Open the settings by right-clicking the widget or typing `/stopmove`. End a cast lock with `/stopmove move` or General > **End the cast lock now**.
- The **Lavender window frame** option (Vex Menu cards stand on their own now).

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
