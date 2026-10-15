/**
 * FP-33 memory-budget fixture (tools/ci-memory-budget.sh). Everything comes from the initial URL:
 *   fp33://cycle?dir=/abs/dir&count=500&per=8&box=192
 * Shows `per` images at a time from img-0.png .. img-<count-1>.png, one row of box x box tiles. The next
 * group mounts once every image of the current group reported onLoad or onError, so no decode is
 * cancelled. After the last group the final `per` images (the most recently used) stay on screen.
 */
import React from 'react';
import {AppRegistry, Image, Linking, View} from 'react-native';

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

function Probe() {
  const [cfg, setCfg] = React.useState(null);
  const [step, setStep] = React.useState(0);
  const settled = React.useRef(0);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setCfg(parse(u || '')))
      .catch(() => setCfg({}));
  }, []);
  if (!cfg) return <View style={{flex: 1, backgroundColor: 'white'}} />;
  const per = Number(cfg.per || 8);
  const count = Number(cfg.count || 0);
  const box = Number(cfg.box || 192);
  const steps = Math.ceil(count / per);
  const cur = Math.min(step, steps - 1);
  const first = Math.min(cur * per, Math.max(0, count - per));
  const onSettled = () => {
    settled.current += 1;
    if (settled.current === per) {
      settled.current = 0;
      if (step < steps - 1) setStep(step + 1);
      else console.log(`FP33 cycled steps=${steps} count=${count}`);
    }
  };
  return (
    <View style={{flex: 1, backgroundColor: 'white'}}>
      {Array.from({length: per}, (_, i) => (
        <Image
          key={`${cur}-${i}`}
          source={{uri: `file://${cfg.dir}/img-${first + i}.png`}}
          resizeMode="stretch"
          onLoad={onSettled}
          onError={onSettled}
          style={{position: 'absolute', left: i * box, top: 0, width: box, height: box}}
        />
      ))}
    </View>
  );
}

AppRegistry.registerComponent('Fp33MemoryBudget', () => Probe);
