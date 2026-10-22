// Blur over moving content. 400x400. A ScrollView of colour tiles fills
// (0,80)..(400,400); an expo-blur <BlurView> header covers (0,0)..(400,140), so
// it straddles the ScrollView's top edge: 80 px of it sits OUTSIDE the
// ScrollView, over a static background, yet its blur reaches into the tiles
// below (intensity 60 ~ sigma 35 px). When the tiles scroll, the whole header
// must re-blur, including the part outside the ScrollView.
// "ready" = 2 s after mount AND 60 requestAnimationFrame callbacks after that:
// rAF only advances while frames are being produced, so ready means the scene
// has been ON SCREEN (the iOS simulator's first frame can take > 2 s: a timer
// alone logged ready over a black screen).
//   BlurScrollMotion  logs `BLURSCROLL ready offset=0` when ready, waits
//                     1.5 s, scrolls 0 -> 100 in 5 px steps every 33 ms
//                     (scrollTo, not animated), then logs `BLURSCROLL done offset=100`.
//   BlurScrollStatic  the same scene already at offset 100 (contentOffset), no
//                     motion; logs `BLURSCROLL ready offset=100` when ready.
// Gate: tools/ci-blur-scroll.sh. Rebuild: tools/build-blur-scroll-bundle.sh.
import React, {useEffect, useRef} from 'react';
import {AppRegistry, ScrollView, View} from 'react-native';
import {BlurView} from 'expo-blur';

const W = 400, H = 400, TOP = 80, HEADER = 140, END = 100, STEP = 5;
const COLS = 8, ROWS = 20, TILE_W = W / COLS, TILE_H = 40, GAP = 2;
// 7 colours: the pattern repeats every 7 rows (280 px), never at the scroll
// distance, or offset 0 and the end offset would look the same.
const PALETTE = ['#e02020', '#f0c020', '#20b040', '#20c0d0', '#2040e0', '#c020c0', '#f07020'];

function Tiles() {
  const tiles = [];
  for (let r = 0; r < ROWS; r++) {
    for (let c = 0; c < COLS; c++) {
      tiles.push(
        <View key={`${r}-${c}`} style={{position: 'absolute', left: c * TILE_W + GAP / 2,
          top: r * TILE_H + GAP / 2, width: TILE_W - GAP, height: TILE_H - GAP,
          backgroundColor: PALETTE[(r + c) % PALETTE.length]}} />,
      );
    }
  }
  return <View style={{width: W, height: ROWS * TILE_H}}>{tiles}</View>;
}

// cb after 2 s and then `frames` animation frames; returns a cancel function.
function whenOnScreen(cb, frames = 60) {
  let live = true;
  const t = setTimeout(() => {
    let n = 0;
    const tick = () => {
      if (!live) return;
      if (++n >= frames) cb();
      else requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, 2000);
  return () => { live = false; clearTimeout(t); };
}

function Scene({motion}) {
  const ref = useRef(null);
  useEffect(() => {
    const timers = [];
    const cancel = whenOnScreen(() => {
      console.log('BLURSCROLL ready offset=' + (motion ? 0 : END));
      if (!motion) return;
      timers.push(setTimeout(() => {
        let y = 0;
        const id = setInterval(() => {
          y = Math.min(END, y + STEP);
          ref.current && ref.current.scrollTo({x: 0, y, animated: false});
          if (y >= END) {
            clearInterval(id);
            setTimeout(() => console.log('BLURSCROLL done offset=' + END), 200);
          }
        }, 33);
        timers.push(id);
      }, 1500));
    });
    return () => { cancel(); timers.forEach(t => clearTimeout(t)); };
  }, [motion]);
  return (
    <View style={{width: W, height: H, backgroundColor: '#202020'}}>
      <ScrollView ref={ref} contentOffset={{x: 0, y: motion ? 0 : END}}
        style={{position: 'absolute', left: 0, top: TOP, width: W, height: H - TOP}}>
        <Tiles />
      </ScrollView>
      <BlurView tint="light" intensity={60}
        style={{position: 'absolute', left: 0, top: 0, width: W, height: HEADER}} />
    </View>
  );
}

// A TAGGED change under part of the blur: one tile at (150,100) 100x40, just
// under the header's lower edge, changes colour 8 times, 100 ms apart. The
// scene graph knows exactly which view changed, so the windowed loop repaints
// only that tile's box (a scroll offset change has no tag and repaints the
// whole window). The header's pixels ABOVE the tile still depend on its colour
// through the blur.
//   BlurTileChange  logs `BLURSCROLL ready` when ready (see whenOnScreen), waits
//                   1.5 s, steps the colour 0 -> 8 (100 ms apart), then logs
//                   `BLURSCROLL done colour=8`.
//   BlurTileStatic  the same scene painted with colour 8 from the start.
const TILE_COLOURS = ['#000000', '#ffffff', '#00ff00', '#ff00ff', '#00ffff', '#ff0000', '#ffff00',
  '#0000ff', '#ffffff'];
function TileScene({change}) {
  const [i, setI] = React.useState(change ? 0 : TILE_COLOURS.length - 1);
  useEffect(() => {
    const timers = [];
    const cancel = whenOnScreen(() => {
      console.log('BLURSCROLL ready');
      if (!change) return;
      timers.push(setTimeout(() => {
        let k = 0;
        const id = setInterval(() => {
          k += 1;
          setI(k);
          if (k >= TILE_COLOURS.length - 1) {
            clearInterval(id);
            setTimeout(() => console.log('BLURSCROLL done colour=' + k), 200);
          }
        }, 100);
        timers.push(id);
      }, 1500));
    });
    return () => { cancel(); timers.forEach(t => clearTimeout(t)); };
  }, [change]);
  return (
    <View style={{width: W, height: H, backgroundColor: '#202020'}}>
      <View style={{position: 'absolute', left: 0, top: TOP, width: W, height: H - TOP}}>
        <Tiles />
      </View>
      <View style={{position: 'absolute', left: 150, top: 100, width: 100, height: 40,
        backgroundColor: TILE_COLOURS[i]}} />
      <BlurView tint="light" intensity={60}
        style={{position: 'absolute', left: 0, top: 0, width: W, height: HEADER}} />
    </View>
  );
}

AppRegistry.registerComponent('BlurScrollMotion', () => () => <Scene motion />);
AppRegistry.registerComponent('BlurScrollStatic', () => () => <Scene motion={false} />);
AppRegistry.registerComponent('BlurTileChange', () => () => <TileScene change />);
AppRegistry.registerComponent('BlurTileStatic', () => () => <TileScene change={false} />);
