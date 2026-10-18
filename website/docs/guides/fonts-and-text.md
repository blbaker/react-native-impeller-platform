---
title: Fonts and text
---

# Fonts and text

## Family resolution

A React Native `fontFamily` can be a single name or, through libraries like
NativeWind, a CSS-style stack: `"Inter, Helvetica, sans-serif"`. The engine's
`ResolveFontFamily` function turns that stack into the one family name
Impeller actually receives: it picks the first entry that resolves and maps
the generic names (`monospace`, `serif`, `sans-serif`, `system-ui`, and the
`ui-*` family) to a concrete face for the current OS. Both text measurement
and paint call the same function, so they can't disagree about which face a
string resolves to.

## Fallback for glyphs the primary face doesn't have

Impeller's own font collection doesn't fall back when the primary face is
missing a glyph. Without help, emoji, CJK, and Arabic text paint as tofu
boxes instead of the right glyph.

On Linux, the engine works around this itself: text is split into runs by
which face actually covers each codepoint, fontconfig is asked for a face
that covers the run, and that face is registered with Impeller for just that
run. Measurement and paint both go through this splitter, so a multi-script
string lays out consistently.

On macOS and Windows, this isn't needed. CoreText and the native Windows
text stack fall back on their own, so the splitter returns the whole string
as a single segment there.

## Adding your own fonts, on Linux

Impeller's resolver can see fonts outside the system catalog if you point it
at a directory, with `--font-dir` or the `RNI_FONT_DIRS` environment
variable. That's how a Linux build picks up app-bundled fonts rather than
only what's already installed on the host.

## A caveat on tabular figures

`nw:tabularNums`, the NativeWind utility for `font-variant: tabular-nums`,
isn't implemented in the style layer yet. react-native-css emits no
`fontVariant` for it, and Apple's faces already use proportional digits by
default, so the visible effect differs by backend today. This is tracked as
a known gap, not a silent miss: see
[Supported components and style props](../reference/supported-components-and-style-props)
for the rest of what's covered and what isn't.

## Why the Linux text gates pin a specific font

Text with no `fontFamily` set gets Impeller's own default face, which on
Linux is the first installed font from a fixed list: Ubuntu, Cantarell,
DejaVu Sans, Liberation Sans, then Arial. That lookup doesn't go through
fontconfig. The style-audit gates were measured with the Ubuntu font
installed as that default. Without it, Linux falls through to DejaVu Sans:
every text tile gets wider, and several gates (underline, line-through,
justify, head ellipsis, and tabular figures) move under their thresholds.
Fonts referenced by name still resolve normally through fontconfig either
way; only the *unset* `fontFamily` case is affected.
