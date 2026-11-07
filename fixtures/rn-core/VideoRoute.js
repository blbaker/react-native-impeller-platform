/**
 * rn-core fixture, video route (rncore://video): ImpellerVideo's <VideoView>
 * playing the numbered test video (tools/build-rn-core-video.sh). Split out of
 * index.js; the route table there picks it.
 */
import React from 'react';
import {TurboModuleRegistry, View} from 'react-native';

export default function VideoRoute({cfg}) {
  // <VideoView> of cfg.src (absolute path) at (0, 0) 320 x 180, contentFit fill.
  // mode=play: play at cfg.rate, shot A after cfg.start ms, shot B cfg.gap ms later.
  // mode=pause: play, then pause just before shot A; B must show the same frame.
  // mode=seek: paused, currentTime = cfg.seek, then one shot.
  const Video = require('react-native-impeller-platform/src/video');
  const mode = cfg.mode || 'play';
  const player = Video.useVideoPlayer(cfg.src ? {uri: `file://${cfg.src}`} : null, (p) => {
    p.loop = false;
    p.playbackRate = Number(cfg.rate || 1);
  });
  React.useEffect(() => {
    const shot = TurboModuleRegistry.get('RNViewShot');
    const timers = [];
    const later = (ms, fn) => timers.push(setTimeout(fn, ms));
    const capture = (tag) => {
      const t = player.currentTime;
      shot
        .captureScreen({format: 'png', result: 'tmpfile', quality: 1, fileName: `rncore-video-${tag}`})
        .then((uri) =>
          console.log(`RNCORE_VIDEO shot tag=${tag} t=${t.toFixed(3)} playing=${player.playing} uri=${uri}`),
        )
        .catch((e) => console.log(`RNCORE_VIDEO shot tag=${tag} ERROR ${e && e.message}`));
    };
    const t0 = Date.now();
    const waitReady = () => {
      const st = player.status;
      if (st === 'readyToPlay') {
        const sz = player.videoSize;
        console.log(
          `RNCORE_VIDEO ready backend=${Video.backend()} w=${sz.width} h=${sz.height} duration=${player.duration.toFixed(3)} rate=${player.playbackRate} after=${Date.now() - t0}ms`,
        );
        run();
      } else if (st === 'error') {
        console.log(`RNCORE_VIDEO error ${player.error && player.error.message}`);
      } else if (Date.now() - t0 > 5000) {
        console.log(`RNCORE_VIDEO error timeout status=${st}`);
      } else {
        later(10, waitReady);
      }
    };
    const start = Number(cfg.start || 500);
    const gap = Number(cfg.gap || 1000);
    const run = () => {
      if (mode === 'seek') {
        player.currentTime = Number(cfg.seek || 0);
        later(300, () => capture('S'));
        return;
      }
      player.play();
      if (mode === 'pause') later(start - 50, () => player.pause());
      later(start, () => capture('A'));
      later(start + gap, () => {
        capture('B');
        const s = player.stats;
        console.log(`RNCORE_VIDEO stats shown=${s.framesShown} dropped=${s.framesDropped} t=${player.currentTime.toFixed(3)}`);
      });
    };
    if (!player.id) console.log('RNCORE_VIDEO error no source');
    else waitReady();
    return () => timers.forEach(clearTimeout);
  }, [player]);
  return (
    <View style={{flex: 1, backgroundColor: 'black'}}>
      <Video.VideoView
        player={player}
        contentFit="fill"
        style={{position: 'absolute', left: 0, top: 0, width: 320, height: 180}}
      />
    </View>
  );
}
