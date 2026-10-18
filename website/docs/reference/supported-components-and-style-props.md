---
title: Supported components and style props
---

# Supported components and style props

This page lists what the style-coverage gates actually pass today, drawn
straight from the tiles the audit tracks (`tools/style-coverage-keep.txt`
and `tools/style-coverage-landed.txt`), not from a feature list written by
hand. A "tile" is one small fixture rendered and checked pixel by pixel.
For the two caveats that affect this list, see [Styling](../guides/styling).

## Layout

Flexbox layout, logical properties (`insetInlineStart`, `marginBlock`, and
so on), RTL direction, percent sizing, `maxWidth`, `flexGrow`,
`aspectRatio`, `overflow: scroll`, and negative `zIndex` all pass.

## Borders, radius, and gradients

Per-side border width and color, elliptical and uneven corner radius,
dashed borders with a per-side color, and `borderCurve` all pass. Gradients
cover angle, hard stops, multiple layers, color hints, radial gradients
(through NativeWind), and a gradient drawn over a background color.

## Shadows

The iOS-style box shadow props pass in their multi-shadow, spread, rounded,
and object forms, including a shadow with no background color and one that
only sets opacity. Elevation (Android-style) with rounded corners passes
too.

## Transforms

Rotate (Z and X), scale, skew, translate by percent, an explicit matrix, a
transform written as a string, a custom transform origin, perspective
combined with rotateX, and nested transforms all pass.

## Color and text

Every CSS color format the style layer accepts passes: HSL, HWB, 4-digit
hex, named colors, and alpha. Text decoration (underline plus
line-through together, double and dotted styles), `textTransform`
(capitalize, lowercase), ellipsis with clipping, `numberOfLines={2}`, and a
rotated text box all pass, including nested weight and decoration changes
inside one string.

## TextInput and Image

TextInput styling (box style, centered multiline text, color, opacity) and
Image styling (`backgroundImage`-style background, `contain`, `cover`,
`center`, and `repeat`) both pass, along with a styled `Switch` (including
disabled) and `Button`.

## NativeWind utility classes

A wide set of NativeWind utilities passes directly: background color and
opacity modifiers, arbitrary colors, CSS variables, padding, row gap,
fractional widths, rounded corners (including `rounded-full` and
per-corner), borders (including dashed), shadows (including an arbitrary
shadow and `shadow-lg`), rings, opacity, rotate/scale/skew, blur, grayscale,
blend modes, outlines, `hidden`/`invisible`, `overflow-hidden`, and the
typography utilities (size, bold, italic, underline, decoration color,
tracking, leading, centered text, uppercase).

## Interaction and responsive variants

`:hover`, group-hover, `:active`, and `:focus` all pass. So do the
responsive and scheme variants: platform variants (`ios`, `android`,
`native`, `web`), breakpoints, landscape/portrait, light/dark, `ltr`/`rtl`,
`contrast-more`, and container queries (`@container`), in both light and
dark mode.

## Known gaps

- **Tabular figures.** `nw:tabularNums` isn't implemented; see
  [Fonts and text](../guides/fonts-and-text#a-caveat-on-tabular-figures).
- **Platform colors, emoji, CJK, and Arabic text** render correctly, but
  through a dedicated fallback path rather than the primary font directly.
  See [Fonts and text](../guides/fonts-and-text#fallback-for-glyphs-the-primary-face-doesnt-have).
- **Stroked SVG icons on the GL backend** (Linux, Windows, and macOS until
  native Metal lands) get no partial-coverage edge antialiasing from
  Impeller itself. The engine renders them into an offscreen texture at 4x
  and downsamples with a linear filter to synthesize the AA; this is
  enabled by default on macOS today and off elsewhere while the technique
  is validated further.

This list reflects the gates as they exist on `main`. A platform that is
listed but hasn't passed its own `tools/ci-style-coverage.sh` run isn't
claimed as supported anywhere in these docs.
