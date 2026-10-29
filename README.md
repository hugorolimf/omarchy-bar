<div align="center">

# Island Bar

**A calmer top bar for Omarchy.**
Widgets on rounded islands, thin stroke icons, short tips on hover, and a drawer
that keeps the bar tidy.

![Island Bar](preview.png)

</div>

## Why this one

- 🏝️ **Islands.** Group widgets (tools, status, system…) on soft rounded islands
  instead of one long row. Empty islands take no room.
- ✏️ **One icon language.** Thin monochrome strokes on a 24-unit grid, drawn by the
  bar over each widget (which still takes the clicks). Colour only when it means
  something: green charging, amber attention, red alert, blue in use, dim off.
- 💬 **Tips that explain.** Hover an icon for its name and value (`Sound · 65%`,
  `Wi‑Fi · MyNetwork`, `Battery · 3h20 left`); click for the full panel. Hovering
  never widens or moves anything. AI usage (Omarchy's agents widget) always shows
  the tightest limit, amber from 70 %, red from 90 %.
- 🧰 **Tools drawer.** The tools button opens a panel with every plugin on the bar,
  by island: open one, pin it to the bar or keep it in the drawer, add installed
  widgets, switch background plugins on and off. Right-click it to organise right
  on the bar.
- 🌫️ **Translucent with real blur** behind it.
- 🌍 English and Portuguese, following your system language.
- 🔄 **Drop-in.** It is Omarchy's own bar underneath, so every widget, section and
  setting you already have keeps working.

## Install

```bash
omarchy plugin add https://github.com/hugorolimf/omarchy-bar --enable
omarchy-restart-shell
```

Switching bars needs one shell restart. The tools panel is drawn with
[Island Kit](https://github.com/hugorolimf/omarchy-island-kit); install it too
(the bar itself works without it, and the tools button tells you if it's missing):

```bash
omarchy plugin add https://github.com/hugorolimf/omarchy-island-kit --enable
```

## Islands

Give consecutive bar entries the same `group` in `~/.config/omarchy/shell.json`
and they share an island. Entries without a group stand on their own.

```jsonc
"right": [
  { "id": "io.github.hugorolimf.bar", "group": "tools" },
  { "id": "omarchy.agents",           "group": "tools" },
  { "id": "omarchy.network",          "group": "system" },
  { "id": "omarchy.audio",            "group": "system" }
]
```

`io.github.hugorolimf.bar` as a bar entry is the tools button. Add `"drawer": true`
to an entry to keep it in the drawer. `omarchy-shell io.github.hugorolimf.bar peek`
shows every value for four seconds.

## Pairs well with

The Island family draws on the same look: [Island Kit](https://github.com/hugorolimf/omarchy-island-kit)
(a catalog that installs all of them), [Island Clock](https://github.com/hugorolimf/omarchy-clock),
and the notch, iPhone and panels as they're released. The bar knows their icons and tips.

## Files it writes

- `~/.local/state/omarchy/toggles/hypr/hugorolimf-bar-blur.lua`: one Hyprland
  layer rule that blurs what is behind the bar (namespace `omarchy-bar`). Omarchy
  loads this folder on every Hyprland reload. Delete it and run `hyprctl reload`
  to turn the blur off.

## Remove

```bash
omarchy plugin remove io.github.hugorolimf.bar
omarchy-restart-shell
rm -f ~/.local/state/omarchy/toggles/hypr/hugorolimf-bar-blur.lua && hyprctl reload
```

Omarchy's own bar comes back.

## Credits

Built on Omarchy's `omarchy.bar` by David Heinemeier Hansson and the
[Omarchy](https://github.com/basecamp/omarchy) contributors (MIT). Layout, widget
loading and settings are theirs; islands, icons, tips, the tools drawer, the
localisation and the blur are this plugin's.

## License

[MIT](LICENSE)
