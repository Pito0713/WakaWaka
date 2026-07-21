# WakaWaka menu bar skin

Canonical source for the menu bar ghost skin. At runtime the app loads skins from
`~/.wakawaka/skins/<name>/` (see `SkinManager.swift`) — this folder is the
version-controlled copy so the art is never lost.

## Install / restore

```bash
mkdir -p ~/.wakawaka/skins
cp -R cost-aware-approval/app/WakaWaka/skins/arcade ~/.wakawaka/skins/
```

## `arcade/` frames

Red Blinky (idle) and a yellow variant (pending), 18×18 pt @2x (36 px PNG),
`skin.json` sets `template: false` (full colour).

| file pattern | meaning |
|---|---|
| `idle_0…4.png` | looking right; `_0…_4` = seamless feet-glide phases |
| `look_left_0…4` / `look_up_0…4` / `look_down_0…4` | eye directions (pending scan) |
| `blink_0…4` | eyes closed |
| `pending_*` | yellow colour set, shown while an approval is waiting |

If this folder is absent from `~/.wakawaka`, the app falls back to a built-in
procedural ghost (`AppDelegate.makeGhostIcon`).
