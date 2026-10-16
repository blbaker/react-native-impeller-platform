/**
 * FP-43 fixture for tools/ci-snapshot.sh (windowed 400x300 pt, --scale 1 or 2).
 *   window  #202020, a green box (300,30) 60x60 and a caption at (40,230) OUTSIDE the target
 *   target  (40,30) 240x180, #f4ecd8, 2 pt navy border:
 *             text   "Snapshot FP-43" bold 20 + "upright 0123" 14 at the top
 *             image  file://<dir>/photo.png 120x80 at (10,90) inside the target
 *             marker red 40x24 at (186,146) inside the target (bottom-right)
 * After the image loaded and two frames painted, JS calls RNViewShot through
 * the package's view-shot API and logs each result:
 *   FP43 png uri=<file uri>            captureRef default (png, tmpfile, device scale)
 *   FP43 b64 len=<n> head=<64 chars>   result base64 (same pixels, same encoder)
 *   FP43 datauri head=<30 chars>
 *   FP43 jpg uri=<file uri>            format jpg quality 0.9
 *   FP43 sized uri=<file uri>          width 120 height 90 (output pixels)
 *   FP43 screen uri=<file uri>         captureScreen
 *   FP43 reject msg=<message>          captureRef on a tag that does not exist
 *   FP43 released uri=<file uri>       a png capture deleted by releaseCapture
 *   FP43 done
 *   fp43://run?dir=/abs/dir
 */
import React from 'react';
import {AppRegistry, Image, Linking, Text, View} from 'react-native';
import {captureRef, captureScreen, releaseCapture} from '@react-native-impeller/core/src/viewshot';

function parse(url) {
  const q = {};
  const i = url.indexOf('?');
  if (i < 0) return q;
  for (const kv of url.slice(i + 1).split('&')) {
    const eq = kv.indexOf('=');
    if (eq > 0) q[kv.slice(0, eq)] = decodeURIComponent(kv.slice(eq + 1));
  }
  return q;
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function run(ref) {
  const png = await captureRef(ref, {format: 'png', result: 'tmpfile'});
  console.log(`FP43 png uri=${png}`);
  const b64 = await captureRef(ref, {format: 'png', result: 'base64'});
  console.log(`FP43 b64 len=${b64.length} head=${b64.slice(0, 64)}`);
  const du = await captureRef(ref, {format: 'png', result: 'data-uri'});
  console.log(`FP43 datauri head=${du.slice(0, 30)} len=${du.length}`);
  const jpg = await captureRef(ref, {format: 'jpg', quality: 0.9, result: 'tmpfile'});
  console.log(`FP43 jpg uri=${jpg}`);
  const sized = await captureRef(ref, {format: 'png', width: 120, height: 90});
  console.log(`FP43 sized uri=${sized}`);
  const screen = await captureScreen({format: 'png'});
  console.log(`FP43 screen uri=${screen}`);
  try {
    await captureRef(987654, {format: 'png'});
    console.log('FP43 reject none');
  } catch (e) {
    console.log(`FP43 reject msg=${e && e.message}`);
  }
  const rel = await captureRef(ref, {format: 'png', fileName: 'fp43-release'});
  releaseCapture(rel);
  console.log(`FP43 released uri=${rel}`);
}

function Snapshot() {
  const [cfg, setCfg] = React.useState(null);
  const [loaded, setLoaded] = React.useState(false);
  const ref = React.useRef(null);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setCfg(parse(u || '')))
      .catch(() => setCfg({}));
  }, []);
  React.useEffect(() => {
    if (!loaded) return;
    wait(300)
      .then(() => run(ref))
      .then(() => console.log('FP43 done'))
      .catch((e) => console.log(`FP43 error ${e && e.message}`));
  }, [loaded]);
  if (!cfg) return <View style={{flex: 1, backgroundColor: '#202020'}} />;
  return (
    <View style={{flex: 1, backgroundColor: '#202020'}}>
      <View
        ref={ref}
        collapsable={false}
        style={{position: 'absolute', left: 40, top: 30, width: 240, height: 180,
          backgroundColor: '#f4ecd8', borderWidth: 2, borderColor: '#203060'}}>
        <Text style={{position: 'absolute', left: 10, top: 8, color: '#102040', fontSize: 20,
          fontWeight: 'bold'}}>Snapshot FP-43</Text>
        <Text style={{position: 'absolute', left: 10, top: 40, color: '#803010', fontSize: 14}}>
          upright 0123
        </Text>
        <Image
          source={{uri: `file://${cfg.dir}/photo.png`}}
          resizeMode="stretch"
          onLoad={() => {
            console.log('FP43 image loaded');
            setLoaded(true);
          }}
          style={{position: 'absolute', left: 10, top: 90, width: 120, height: 80}}
        />
        <View style={{position: 'absolute', left: 186, top: 146, width: 40, height: 24,
          backgroundColor: '#e02020'}} />
      </View>
      <View style={{position: 'absolute', left: 300, top: 30, width: 60, height: 60,
        backgroundColor: '#20c040'}} />
      <Text style={{position: 'absolute', left: 40, top: 230, color: '#ffffff', fontSize: 16}}>
        outside the target
      </Text>
    </View>
  );
}

AppRegistry.registerComponent('Snapshot', () => Snapshot);
