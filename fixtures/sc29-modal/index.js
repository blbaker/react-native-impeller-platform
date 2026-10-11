/**
 * SC-29 / A22: <Modal> as an overlay surface. Window 400x300.
 * Scenes (--initial-url): probe://transparent (default), probe://opaque.
 *   grey root; blue Pressable APP at (20,200) 100x80;
 *   a holder with a transparent 50 px border, so the ModalHostView's own
 *   frame origin is (50,50) (absolute children sit at the padding box, so
 *   padding would not move it); the modal content is laid out in WINDOW coordinates:
 *     green box at (150,40) 100x80, purple Pressable MODAL at (280,200) 100x80;
 *   a LATER sibling red box at (130,30) 100x60 that overlaps the green box,
 *   so an in-tree modal would be covered by it.
 * Logs: SHOW (onShow), REQUEST_CLOSE (onRequestClose, closes the modal),
 * PRESS APP / PRESS MODAL.
 */
const React = require('react');
const { AppRegistry, View, Modal, Pressable, Linking } = require('react-native');
const h = React.createElement;

const abs = (left, top, width, height, backgroundColor) =>
  ({ position: 'absolute', left, top, width, height, backgroundColor });

function App() {
  const [scene, setScene] = React.useState(null);
  const [visible, setVisible] = React.useState(true);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setScene((u || 'probe://transparent').replace('probe://', '')))
      .catch(() => setScene('transparent'));
  }, []);
  if (scene == null) return null;
  return h(View, { style: { flex: 1, backgroundColor: 'rgb(200,200,200)' } },
    h(Pressable, { style: abs(20, 200, 100, 80, 'rgb(0,0,255)'), onPress: () => console.log('PRESS APP') }),
    h(View, { style: { position: 'absolute', left: 0, top: 0, width: 200, height: 150, borderWidth: 50, borderColor: 'rgba(255,255,255,0)' } },
      h(Modal, {
        visible,
        transparent: scene === 'transparent',
        animationType: 'none',
        onShow: () => console.log('SHOW'),
        onRequestClose: () => { console.log('REQUEST_CLOSE'); setVisible(false); },
      },
        h(View, { style: abs(150, 40, 100, 80, 'rgb(0,255,0)') }),
        h(Pressable, { style: abs(280, 200, 100, 80, 'rgb(128,0,128)'), onPress: () => console.log('PRESS MODAL') }))),
    h(View, { style: abs(130, 30, 100, 60, 'rgb(255,0,0)') }));
}

AppRegistry.registerComponent('probe', () => App);
