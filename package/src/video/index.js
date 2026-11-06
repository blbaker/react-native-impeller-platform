'use strict';
// Row 3: video on the engine, with expo-video's JS shape.
//
//   import {useVideoPlayer, VideoView} from 'react-native-impeller-platform/src/video';
//   const player = useVideoPlayer({uri: 'file:///abs/route.mp4'}, (p) => { p.loop = true; p.play(); });
//   player.playbackRate = 1.4;  player.pause();  player.play();  player.currentTime = 42;
//   <VideoView player={player} contentFit="cover" style={{width: '100%', height: '100%'}} />
//
// The engine's "ImpellerVideo" module decodes on its own thread with a media
// clock and paints through <ImpellerTextureView textureId> (FP-42), so frames
// advance without any JS work. Same `get` (not `getEnforcing`) pattern as
// ../externaltexture: an engine without the module fails only the calls that need it.
const React = require('react');
const {TurboModuleRegistry, View} = require('react-native');
const {ImpellerTextureView} = require('../externaltexture');

const Native = TurboModuleRegistry.get('ImpellerVideo');

function mod() {
  if (Native == null) {
    throw new Error(
      'ImpellerVideo native module is unavailable. The engine binary predates video ' +
        'support: update the engine.',
    );
  }
  return Native;
}

function isSupported() {
  return Native != null && Native.isSupported();
}

function uriOf(source) {
  if (typeof source === 'string') return source;
  if (source && typeof source.uri === 'string') return source.uri;
  if (typeof source === 'number') {
    const resolve = require('react-native/Libraries/Image/resolveAssetSource').default;
    const r = resolve(source);
    if (r && r.uri) return r.uri;
  }
  throw new Error('VideoPlayer: source must be a uri string, {uri}, or a require()d asset');
}

class VideoPlayer {
  constructor(source) {
    this._id = source == null ? 0 : mod().create(uriOf(source));
    this._loop = false;
    this._rate = 1;
    this._released = false;
  }
  get id() {
    return this._id;
  }
  _status() {
    if (!this._id || this._released) {
      return {status: 'idle', currentTime: 0, duration: 0, playing: false, width: 0, height: 0};
    }
    return mod().getStatus(this._id);
  }
  play() {
    if (this._id) mod().play(this._id);
  }
  pause() {
    if (this._id) mod().pause(this._id);
  }
  replace(source) {
    const loop = this._loop;
    const rate = this._rate;
    this.release();
    this._released = false;
    this._id = mod().create(uriOf(source));
    this.loop = loop;
    this.playbackRate = rate;
  }
  seekBy(seconds) {
    this.currentTime = this.currentTime + seconds;
  }
  replay() {
    this.currentTime = 0;
    this.play();
  }
  release() {
    if (this._id && !this._released) mod().release(this._id);
    this._released = true;
  }
  get playing() {
    return !!this._status().playing;
  }
  get paused() {
    return !this.playing;
  }
  get currentTime() {
    return this._status().currentTime;
  }
  set currentTime(seconds) {
    if (this._id) mod().seek(this._id, Number(seconds));
  }
  get duration() {
    return this._status().duration;
  }
  get playbackRate() {
    return this._id ? this._status().rate : this._rate;
  }
  set playbackRate(rate) {
    this._rate = Number(rate);
    if (this._id) mod().setRate(this._id, this._rate);
  }
  get loop() {
    return this._loop;
  }
  set loop(on) {
    this._loop = !!on;
    if (this._id) mod().setLoop(this._id, this._loop);
  }
  // 'idle' | 'loading' | 'readyToPlay' | 'error' (expo-video's VideoPlayerStatus)
  get status() {
    return this._status().status;
  }
  get error() {
    const s = this._status();
    return s.status === 'error' ? {message: s.error} : null;
  }
  // Engine extras, for tests and diagnostics.
  get videoSize() {
    const s = this._status();
    return {width: s.width, height: s.height};
  }
  get stats() {
    const s = this._status();
    // audio: 'none' | 'on' | 'muted' (rate is not 1) | 'error: ...'; audioFrames: 48 kHz frames played.
    return {
      framesShown: s.framesShown,
      framesDropped: s.framesDropped,
      ended: s.ended,
      audio: s.audio,
      audioFrames: s.audioFrames,
    };
  }
}

function createVideoPlayer(source) {
  return new VideoPlayer(source);
}

function useVideoPlayer(source, setup) {
  const key = source == null ? '' : uriOf(source);
  const ref = React.useRef(null);
  if (ref.current == null || ref.current.key !== key) {
    if (ref.current) ref.current.player.release();
    const player = new VideoPlayer(source);
    if (setup) setup(player);
    ref.current = {key, player};
  }
  const player = ref.current.player;
  React.useEffect(() => () => player.release(), [player]);
  return player;
}

// contentFit: 'contain' (default, like expo-video) | 'cover' | 'fill'.
function fitStyle(fit, video, box) {
  if (fit === 'fill' || !video.width || !video.height) {
    return {position: 'absolute', left: 0, top: 0, width: box.width, height: box.height};
  }
  const sx = box.width / video.width;
  const sy = box.height / video.height;
  const s = fit === 'cover' ? Math.max(sx, sy) : Math.min(sx, sy);
  const w = video.width * s;
  const h = video.height * s;
  return {position: 'absolute', left: (box.width - w) / 2, top: (box.height - h) / 2, width: w, height: h};
}

function VideoView({player, contentFit = 'contain', style, onLayout, ...rest}) {
  const [box, setBox] = React.useState(null);
  const [size, setSize] = React.useState(null);
  React.useEffect(() => {
    setSize(null);
    if (!player || !player.id) return undefined;
    let timer = null;
    const poll = () => {
      const s = player.videoSize;
      if (s.width > 0 && s.height > 0) setSize(s);
      else if (player.status !== 'error') timer = setTimeout(poll, 16);
    };
    poll();
    return () => timer && clearTimeout(timer);
  }, [player, player && player.id]);
  return React.createElement(
    View,
    {
      ...rest,
      style: [{overflow: 'hidden'}, style],
      onLayout: (e) => {
        const {width, height} = e.nativeEvent.layout;
        setBox({width, height});
        if (onLayout) onLayout(e);
      },
    },
    player && player.id && box && size
      ? React.createElement(ImpellerTextureView, {
          textureId: player.id,
          style: fitStyle(contentFit, size, box),
        })
      : null,
  );
}

module.exports = {
  isSupported,
  createVideoPlayer,
  useVideoPlayer,
  VideoView,
  VideoPlayer,
  backend: () => (Native == null ? 'none' : Native.backend()),
};
