# Flightdeck brand assets

Flightdeck uses the **Vector Eight / Beacon** identity: a white airframe, blue
command path, and amber operator-attention node on a near-black console field.

## Files

- `flightdeck-mark.svg` — transparent master mark
- `flightdeck-mark-monochrome.svg` — single-color master for constrained contexts
- `flightdeck-avatar.svg` / `.png` — square GitHub avatar
- `flightdeck-lockup.svg` — horizontal mark and wordmark
- `flightdeck-splash-800x480.svg` / `.png` — Stream Deck Silent Boot splash
- `flightdeck-wallpaper-768x384.svg` / `.png` — Stream Deck XL sleep wallpaper
- `flightdeck-social-preview-1280x640.svg` / `.png` — GitHub social preview

## The wallpaper and the splash are one image

`flightdeck-wallpaper-768x384` is the splash letterboxed to the XL panel: the
800×480 source scaled 0.8 to 640×384 and centred, leaving a 64px Night bar on
each side. That is exactly the geometry `plugin/src/splash.ts` applies per key,
so the boot splash and the sleep wallpaper show the same artwork in the same
place and the deck does not shift it when it falls asleep.

Edit one and you must edit the other. `tools/check-wallpaper.mjs` composites
the real per-key tiles and diffs them against the wallpaper to catch drift; it
needs Google Chrome, so it is not part of the bats suite.

The PNG is 1:1 with the XL panel's 768×384 physical pixels — there is nothing
to gain from a 2× render, as the app would only scale it back down.

## Palette

- Night `#020304`
- Airframe `#EEF5FF`
- Command `#1256A3`
- Attention `#F5A623`
- Mark interior `#0C131D`
- Secondary text `#617083`

## Usage rules

Amber means operator attention; do not use it decoratively. Blue indicates the
active command path. Keep the mark flat and geometric. Glow is permitted only
as a subtle, temporary effect in startup animation—not in the static avatar or
primary mark.
