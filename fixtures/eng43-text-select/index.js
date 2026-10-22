/**
 * TEXT-SELECT-1 (ENG-43): can one mouse drag select text across two
 * <Text selectable>?
 *
 * The Mac agent's probe fixture (Jim repo tools/text-select-probe/index.js),
 * committed here verbatim so tools/ci-text-select.sh runs the same drags on
 * the same scene. App name stays 'probe' so the Mac's
 * tools/text-select-probe.py can render this bundle unchanged.
 *
 * Every band sits at a fixed absolute position so the probe's drag points are
 * plain numbers (tools/text-select-probe.py):
 *   P1, P2   two sibling paragraphs, the shape every chat markdown block has
 *            (ChatMarkdownBody.tsx draws each block as its own Text).
 *   CONTROL  ONE Text holding two lines, dragged with the same shape as P1
 *            to P2. It must select across its own lines, which proves the
 *            drag reaches line two at all.
 *   RUNS     three sibling Text in a row, the shape a styled line has
 *            (ChatMdRuns.tsx splits it into one Text per word).
 *   NESTED   one Text with a bold nested child, which the engine selects
 *            whole (nested Text paints since D-67 expired).
 */
const React = require('react');
const { AppRegistry, View, Text } = require('react-native');

const INK = { color: 'rgb(255, 255, 255)', fontSize: 20, lineHeight: 24 };
const at = (top) => ({ position: 'absolute', left: 20, top });
const e = React.createElement;

function Probe() {
  return e(
    View,
    { style: { flex: 1, backgroundColor: 'rgb(0, 0, 0)' } },
    e(Text, { selectable: true, style: [INK, at(20)] }, 'Alpha one two three.'),
    e(Text, { selectable: true, style: [INK, at(60)] }, 'Bravo four five six.'),
    e(Text, { selectable: true, style: [INK, at(110)] }, 'Echo one two three.\nFoxtrot four five six.'),
    e(
      View,
      { style: [at(180), { flexDirection: 'row' }] },
      e(Text, { selectable: true, style: INK }, 'Charlie '),
      e(Text, { selectable: true, style: [INK, { fontWeight: '600' }] }, 'seven '),
      e(Text, { selectable: true, style: INK }, 'eight.'),
    ),
    e(
      Text,
      { selectable: true, style: [INK, at(230)] },
      'Delta ',
      e(Text, { style: { fontWeight: '600' } }, 'nine'),
      ' ten.',
    ),
  );
}

AppRegistry.registerComponent('probe', () => Probe);
