/**
 * ImpellerVideo sound, driven by tools/ci-video-audio.sh. One committed bundle;
 * the scenario comes from the initial URL:
 *
 *   vaud://play?src=<uri, percent-encoded>&secs=N
 *        [&rates=0.6@6,1@10]        at 6 s after ready: playbackRate 0.6, at 10 s: 1
 *        [&pauseAt=S&playAt=T]      pause() at S s, play() at T s
 *        [&releaseAt=S]             release() at S s, timed
 *
 * Log lines (all start with VAUD; wall = Date.now(), the clock the paced test
 * device stamps its capture with):
 *   created id=N | create_error <message>
 *   ready after=<ms> w= h= duration= wall=
 *   s wall= ct= rate= playing= audio=<stats.audio> af=<audioFrames> shown= dropped=   (every 100 ms)
 *   rate at= to= wall=  |  pause at= wall=  |  play at= wall=  |  released at= took=<ms>
 *   error <player.error.message>
 *   done shown= dropped= ct= af= audio=<stats.audio>   (then pause())
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
    console.log(`VAUD created id=${p.id}`);
    return p;
  } catch (e) {
    console.log(`VAUD create_error ${e && e.message}`);
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
    let errored = false;
    let released = false;
    const status = () => {
      const st = player.status;
      if (st === 'error' && !errored) {
        errored = true;
        console.log(`VAUD error ${player.error && player.error.message}`);
      }
      return st;
    };
    const secs = Number(cfg.secs || 10);
    const run = (tReady) => {
      const at = (s, fn) => later(Math.max(0, tReady + s * 1000 - Date.now()), fn);
      player.play();
      for (const r of (cfg.rates || '').split(',').filter(Boolean)) {
        const [rate, when] = r.split('@');
        at(Number(when), () => {
          player.playbackRate = Number(rate);
          console.log(`VAUD rate at=${when} to=${rate} wall=${Date.now()}`);
        });
      }
      if (cfg.pauseAt) {
        at(Number(cfg.pauseAt), () => {
          player.pause();
          console.log(`VAUD pause at=${cfg.pauseAt} wall=${Date.now()}`);
        });
      }
      if (cfg.playAt) {
        at(Number(cfg.playAt), () => {
          player.play();
          console.log(`VAUD play at=${cfg.playAt} wall=${Date.now()}`);
        });
      }
      if (cfg.releaseAt) {
        at(Number(cfg.releaseAt), () => {
          const a = Date.now();
          player.release();
          released = true;
          console.log(`VAUD released at=${cfg.releaseAt} took=${Date.now() - a}`);
        });
      }
      const sample = () => {
        if (released) return;
        const st = status();
        const x = player.stats;
        const ct = player.currentTime;
        console.log(
          `VAUD s wall=${Date.now()} ct=${ct.toFixed(3)} rate=${player.playbackRate} playing=${player.playing} audio=${JSON.stringify(x.audio)} af=${x.audioFrames} shown=${x.framesShown} dropped=${x.framesDropped} status=${st}`,
        );
      };
      const iv = setInterval(sample, 100);
      at(secs, () => {
        clearInterval(iv);
        if (released) return;
        sample();
        player.pause(); // the capture's length is then the play time
        const x = player.stats;
        console.log(
          `VAUD done shown=${x.framesShown} dropped=${x.framesDropped} ct=${player.currentTime.toFixed(3)} af=${x.audioFrames} audio=${JSON.stringify(x.audio)}`,
        );
      });
      timers.push({iv});
    };
    const waitReady = () => {
      const st = status();
      if (st === 'readyToPlay') {
        const sz = player.videoSize;
        console.log(
          `VAUD ready after=${Date.now() - t0} w=${sz.width} h=${sz.height} duration=${player.duration.toFixed(3)} wall=${Date.now()}`,
        );
        run(Date.now());
      } else if (st !== 'error') {
        later(20, waitReady);
      }
    };
    waitReady();
    return () =>
      timers.forEach((t) => (t && t.iv !== undefined ? clearInterval(t.iv) : clearTimeout(t)));
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

function VideoAudio() {
  const [cfg, setCfg] = React.useState(null);
  React.useEffect(() => {
    Linking.getInitialURL()
      .then((u) => setCfg(parse(u || '')))
      .catch(() => setCfg({route: ''}));
  }, []);
  if (!cfg) return <View style={{flex: 1, backgroundColor: 'black'}} />;
  if (cfg.route === 'play' && cfg.src) return <Play cfg={cfg} />;
  console.log(`VAUD bad_url route=${cfg.route}`);
  return <View style={{flex: 1, backgroundColor: 'black'}} />;
}

AppRegistry.registerComponent('VideoAudio', () => VideoAudio);
