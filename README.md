<div align="center">

# Island Bar

**A calmer top bar for Omarchy.**
Widgets on rounded islands, thin stroke icons, and values that slide out when you hover.

![Island Bar](preview.png)

</div>

## Why this one

- 🏝️ **Islands.** Group widgets (tools, status, system…) on soft rounded islands
  instead of one long row. Empty islands take no room.
- ✏️ **One icon language.** Thin monochrome strokes on a 24-unit grid, drawn by the
  bar over each widget (which still takes the clicks). Colour only when it means
  something: green charging, amber attention, red alert, blue in use, dim off.
- 👀 **Values on hover.** Point at an icon and it opens up with its value: volume,
  Wi‑Fi name, Bluetooth device, brightness, microphone, battery with time left.
  AI usage (Omarchy's agents widget) always shows the tightest limit, amber from
  70 %, red from 90 %.
- 💬 **Tooltips that explain** what each icon is and what a click does.
- 🌫️ **Translucent with real blur** behind it.
- 🌍 English and Portuguese, following your system language.
- 🔄 **Drop-in.** It is Omarchy's own bar underneath, so every widget, section and
  setting you already have keeps working.

## Install

```bash
omarchy plugin add https://github.com/hugorolimf/omarchy-bar --enable
omarchy-restart-shell
```

Switching bars needs one shell restart.

## Islands

Give consecutive bar entries the same `group` in `~/.config/omarchy/shell.json`
and they share an island. Entries without a group stand on their own.

```jsonc
"right": [
  { "id": "omarchy.agents",  "group": "tools" },
  { "id": "omaplug",         "group": "tools" },
  { "id": "omarchy.network", "group": "system" },
  { "id": "omarchy.audio",   "group": "system" }
]
```

`omarchy-shell io.github.hugorolimf.bar peek` opens every value for four seconds,
handy to see the hover values at once.

## Files it writes

- `~/.local/state/omarchy/toggles/hypr/hugorolimf-bar-blur.lua`: one Hyprland
  layer rule that blurs what is behind the bar (namespace `omarchy-bar`). Omarchy
  loads this folder on every Hyprland reload. Delete it and run `hyprctl reload`
  to turn the blur off.

## Requirements

- Omarchy with the Quattro shell (Quickshell) and Hyprland's Lua config.
- Fonts: Adwaita Sans and JetBrainsMono Nerd Font (both come with Omarchy).

## Remove

```bash
omarchy plugin remove io.github.hugorolimf.bar
rm -f ~/.local/state/omarchy/toggles/hypr/hugorolimf-bar-blur.lua && hyprctl reload
omarchy-restart-shell
```

Omarchy's own bar comes back.

## Credits

Built on Omarchy's own `omarchy.bar` by David Heinemeier Hansson and the
[Omarchy](https://github.com/basecamp/omarchy) contributors (MIT). Layout, widget
hosting and settings are theirs; the islands, icons, hover values and blur are
this plugin's.

## Pairs well with

[Island Clock](https://github.com/hugorolimf/omarchy-clock) ·
[Glass Dock](https://github.com/hugorolimf/omarchy-dock) ·
[Glass Alt+Tab](https://github.com/hugorolimf/omarchy-alttab) ·
[Glass Notifications](https://github.com/hugorolimf/omarchy-notifications)

## License

[MIT](LICENSE)
