'use strict';
// SC-26. createAnimatedComponent for the stub: a wrapper that resolves
// useAnimatedStyle / useAnimatedProps handles and CSS animation/transition
// style props to plain values on every render, and re-renders itself on the
// clock while anything is moving.
const React = require('react');
const {StyleSheet} = require('react-native');
const {now, onFrame} = require('./clock');
const {HANDLE} = require('./hooks');
const css = require('./css');

// Replace every animated-style handle in a (nested) style with its current
// values, collecting the handles to subscribe to.
function resolveHandles(style, handles) {
  if (Array.isArray(style)) return style.map((s) => resolveHandles(s, handles));
  if (style && typeof style === 'object' && style[HANDLE]) {
    handles.push(style[HANDLE]);
    return style[HANDLE].current();
  }
  return style;
}

function useFrames(activeRef, force) {
  const stop = React.useRef(null);
  React.useEffect(() => {
    if (activeRef.current && !stop.current) {
      stop.current = onFrame(() => {
        if (!activeRef.current) {
          stop.current = null;
          return false;
        }
        force();
        return true;
      });
    }
  });
  React.useEffect(() => () => stop.current && stop.current(), []);
}

const cache = new WeakMap();

function createAnimatedComponent(Component) {
  if (Component == null || (typeof Component !== 'function' && typeof Component !== 'object')) return Component;
  if (cache.has(Component)) return cache.get(Component);
  function Animated(props, ref) {
    const {style, animatedProps, entering, exiting, layout, ...rest} = props;
    const [, force] = React.useReducer((x) => x + 1, 0);
    const handles = [];
    const resolved = resolveHandles(style, handles);
    let extra = null;
    if (animatedProps && animatedProps[HANDLE]) {
      handles.push(animatedProps[HANDLE]);
      extra = animatedProps[HANDLE].current();
    }
    React.useEffect(() => {
      const unsubs = handles.map((h) => h.subscribe(force));
      return () => unsubs.forEach((u) => u());
    });
    const state = React.useRef(null);
    if (!state.current) state.current = css.newState();
    const activeRef = React.useRef(false);
    const flat = StyleSheet.flatten(resolved) || {};
    const parts = css.split(flat);
    let finalStyle = style;
    if (parts.css || state.current.last) {
      const r = css.evaluate(state.current, parts.base, parts.css, now());
      activeRef.current = r.active;
      finalStyle = r.style;
    } else if (handles.length) {
      finalStyle = flat;
    }
    useFrames(activeRef, force);
    return React.createElement(Component, {...rest, ...(extra || {}), style: finalStyle, ref});
  }
  const name = Component.displayName || Component.name || 'Component';
  Animated.displayName = `AnimatedComponent(${name})`;
  const Wrapped = React.forwardRef(Animated);
  Wrapped.displayName = Animated.displayName;
  cache.set(Component, Wrapped);
  return Wrapped;
}

module.exports = {createAnimatedComponent};
