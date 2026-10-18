---
title: Styling
---

# Styling

Style props on a React Native component work the same way here as on iOS
and Android: Fabric commits a style record for each node, and this engine
reads it at mount or update time and builds the matching Impeller draw
calls. There's no CSS engine and no second style resolution pass; whatever
value React Native's style layer resolves is what gets painted.

Two things differ from a native host because the renderer is Impeller
rather than a platform UI toolkit:

## Anti-aliasing depends on the backend

Metal and Vulkan surfaces get edge antialiasing from the surface's own MSAA.
The GL backend (Linux, Windows, and macOS until native Metal lands) has no
surface-level AA, so stroked SVG icons would otherwise come out jagged.
The engine works around it with a supersample-then-downsample pass: it
renders the icon at 4x into an offscreen texture, then composites it down
with a linear filter. This is on by default on macOS and off elsewhere
while the technique is validated further. See
[How it works](./how-it-works#backends-per-os) for the backend list.

## Not every style prop has landed yet

Style and NativeWind coverage is tracked by a pixel-diff gate
(`tools/ci-style-coverage.sh`), not asserted from memory. The full list of
what passes today, and the known gaps, is in
[Supported components and style props](../reference/supported-components-and-style-props).
Two gaps worth knowing up front:

- `nw:tabularNums` (NativeWind's utility for `font-variant: tabular-nums`)
  isn't implemented. See [Fonts and text](./fonts-and-text#a-caveat-on-tabular-figures).
- Platform colors, emoji, CJK, and Arabic text render correctly, but
  through a font-fallback path rather than the primary font directly. See
  [Fonts and text](./fonts-and-text#fallback-for-glyphs-the-primary-face-doesnt-have).

A platform is only listed as passing a style tile once its own
`tools/ci-style-coverage.sh` run proves it; nothing here is aspirational.
