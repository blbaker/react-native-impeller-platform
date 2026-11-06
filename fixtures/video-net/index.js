/**
 * ImpellerVideo over the network (http, https, HLS), driven by tools/ci-video-net.sh.
 * One committed bundle; the scenario comes from the initial URL:
 *
 *   vnet://play?src=<uri, percent-encoded>&secs=N
 *        [&seekAt=S&seekTo=T]       at S s after ready: player.currentTime = T
 *        [&rates=0.6@10,1.25@20]    at 10 s: playbackRate 0.6, at 20 s: 1.25
 *        [&releaseAt=S]             at S s after create: player.release(), timed
 *        [&playEarly=1]             play() right after create, before the source opens
 *
 * Log lines (all start with VNET):
 *   created id=N | create_error <message>
 *   ready after=<ms> w= h= duration=
 *   tick t=<s since ready> status= ct=<currentTime> shown= dropped= rate= playing=
 *   seek at= to=  |  rate at= to=  |  released after=<ms since create> took=<ms>
 *   error <player.error.message>   (once, whenever status turns 'error')
 *   done shown= dropped= ct= status=
 */
import React from 'react';
import {AppRegistry, Linking, View} from 'react-native';

const Video = require('react-native-impeller-platform/src/video');

function parse(url) {
  const q = {route: ''};
  const m = /^[a-z0-9]+:\/\/([^?]*)/.exec(url || '');
  if (m) q.route = m[1];
  const i = (url || '').indexOf('?');
  if (i < 0) return q;
  for (const kv of url.slice(i + 1).split('&')) {
    const eq = kv.indexOf('=');
    if (eq > 0) q[kv.slice(0, eq)] = decodeURIComponent(kv.slice(eq + 1));
  }
  return q;
}

function makePlayer(src) {
  try {
    const p = Video.createVideoPlayer({uri: src});
    console.log(`VNET created id=${p.id}`);
    return p;
  } catch (e) {
    console.log(`VNET create_error ${e && e.message}`);
    return null;
  }
}

function Play({cfg}) {
  const [player] = React.useState(() => makePlayer(cfg.src));
  React.useEffect(() => {
    if (!player) return undefined;
    const timers = [];
    const later = (ms, fn) => timers.push(setTimeout(fn, ms));
    const t0 = Date.now();
    let released = false;
    let errored = false;
    if (cfg.playEarly) player.play();
    const status = () => {
      if (released) return;
      const st = player.status;
      if (st === 'error' && !errored) {
        errored = true;
        console.log(`VNET error ${player.error && player.error.message}`);
      }
      return st;
    };
    if (cfg.releaseAt) {
      later(Number(cfg.releaseAt) * 1000, () => {
        const a = Date.now();
        player.release();
        released = true;
        console.log(`VNET released after=${a - t0} took=${Date.now() - a}`);
      });
    }
    const secs = Number(cfg.secs || 10);
    const run = (tReady) => {
      const at = (s, fn) => later(Math.max(0, tReady + s * 1000 - Date.now()), fn);
      player.play();
      if (cfg.seekAt) {
        at(Number(cfg.seekAt), () => {
          console.log(`VNET seek at=${cfg.seekAt} to=${cfg.seekTo}`);
          player.currentTime = Number(cfg.seekTo);
        });
      }
      for (const r of (cfg.rates || '').split(',').filter(Boolean)) {
        const [rate, when] = r.split('@');
        at(Number(when), () => {
          console.log(`VNET rate at=${when} to=${rate}`);
          player.playbackRate = Number(rate);
        });
      }
      for (let s = 1; s <= secs; ++s) {
        at(s, () => {
          if (released) return;
          const st = status();
          const x = player.stats;
          console.log(
            `VNET tick t=${s} status=${st} ct=${player.currentTime.toFixed(3)} shown=${x.framesShown} dropped=${x.framesDropped} rate=${player.playbackRate} playing=${player.playing}`,
          );
          if (s === secs) {
            console.log(`VNET done shown=${x.framesShown} dropped=${x.framesDropped} ct=${player.currentTime.toFixed(3)} status=${st}`);
          }
        });
      }
    };
    const waitReady = () => {
      if (released) return;
      const st = status();
      if (st === 'readyToPlay') {
        const sz = player.videoSize;
        console.log(`VNET ready after=${Date.now() - t0} w=${sz.width} h=${sz.height} duration=${player.duration.toFixed(3)}`);
        run(Date.now());
      } else if (st !== 'error') {
        later(20, waitReady);
      }
    };
    waitReady();
    return () => timers.forEach(clearTimeout);
  }, [player, cfg]);
  return (
    <View style={{flex: 1, backgroundColor: 'black'}}>
      {player ? (
        <Video.VideoView
          player={player}
          contentFit="fill"
          style={{position: 'absolute', left: 0, top: 0, width: 320, height: 180}}
        />
      ) : null}
    </View>
  );
}

function VideoNet() {
  const [cfg, setCfg] = React.useState(null);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setCfg(parse(u || '')))
      .catch(() => setCfg({route: ''}));
  }, []);
  if (!cfg) return <View style={{flex: 1, backgroundColor: 'black'}} />;
  if (cfg.route === 'play' && cfg.src) return <Play cfg={cfg} />;
  console.log(`VNET bad_url route=${cfg.route}`);
  return <View style={{flex: 1, backgroundColor: 'black'}} />;
}

AppRegistry.registerComponent('VideoNet', () => VideoNet);
