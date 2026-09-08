/**
 * P10 networking fixture — NOT a demo app.
 *
 * ⛔ THE TRAP THIS FIXTURE EXISTS TO CATCH.
 * RN's JavaScript half of networking is COMPLETE without any native module.
 * `whatwg-fetch` installs a global `fetch` that is a genuine function, and
 * XMLHttpRequest.js imports cleanly. So on this engine, before the Networking
 * TurboModule existed:
 *
 *     typeof fetch === 'function'          // true
 *     TurboModuleRegistry.get('Networking') // null
 *     await fetch(anything)                 // never succeeds
 *
 * A gate asserting the first line passes against a totally dead network
 * stack. That is why BOTH halves are painted separately below: `nativeHalf`
 * asserts the module exists, and the request swatches assert real bytes came
 * back from a real server. Either alone is satisfiable by something broken.
 *
 * Inherited P2/P3/P4 rule: a module's result must become a PIXEL. A
 * console.log proves the JS ran, not that the value was right.
 */
import React from 'react';
import {AppRegistry, Text, View} from 'react-native';
import {TurboModuleRegistry} from 'react-native';
import geometry from './fixture.json';

const {
  surface,
  swatchSize,
  baseUrl,
  control,
  nativeHalf,
  getRequest,
  getStatus,
  postRequest,
  responseHeaders,
  errorPath,
  text,
} = geometry;

function Swatch({spec, ok, color}) {
  // The node always exists; only its colour carries the verdict. "Node
  // missing" and "node painted the wrong colour" are different bugs.
  return (
    <View
      style={{
        position: 'absolute',
        left: spec.x,
        top: spec.y,
        width: swatchSize,
        height: swatchSize,
        backgroundColor: ok ? color : (spec.failColor || surface.background),
      }}
    />
  );
}

function rgb(expect) {
  return `rgb(${expect[0]}, ${expect[1]}, ${expect[2]})`;
}

function Fixture() {
  // --- POSITIVE CONTROL -----------------------------------------------------
  // Depends on nothing but React rendering. If this is background, the engine
  // did not boot or Fabric never mounted — which would otherwise be
  // indistinguishable from "every network assertion failed".
  const controlOk = true;

  // --- THE NATIVE HALF ------------------------------------------------------
  // This is the assertion that was false before this phase and that no
  // fetch-shaped check can make. A JS polyfill cannot fake a TurboModule.
  let nativeHalfOk = false;
  try {
    const mod = TurboModuleRegistry.get('Networking');
    nativeHalfOk = mod != null && typeof mod.sendRequest === 'function';
  } catch (e) {
    nativeHalfOk = false;
  }

  const [getOk, setGetOk] = React.useState(false);
  const [statusOk, setStatusOk] = React.useState(false);
  const [postOk, setPostOk] = React.useState(false);
  const [headersOk, setHeadersOk] = React.useState(false);
  const [errorOk, setErrorOk] = React.useState(false);
  const [label, setLabel] = React.useState('pending');

  React.useEffect(() => {
    let measuredStatus = 'none';

    // --- GET: body must equal a token the server was told to return ---------
    const getP = fetch(`${baseUrl}/get`)
      .then(res => res.text().then(body => ({res, body})))
      .then(({res, body}) => {
        setGetOk(body === getRequest.expectBody);
        // Response headers must survive the native -> JS event. Body-only
        // implementations look completely healthy until you read one.
        setHeadersOk(
          res.headers.get(responseHeaders.expectHeader) ===
            responseHeaders.expectHeaderValue,
        );
      })
      .catch(() => {});

    // --- STATUS: a non-200 the module cannot have hardcoded ----------------
    const statusP = fetch(`${baseUrl}/status`)
      .then(res => {
        measuredStatus = String(res.status);
        setStatusOk(res.status === getStatus.expectStatus);
      })
      .catch(() => {});

    // --- POST: method, header and body must all round-trip -----------------
    // The server echoes what it actually received. This is what catches a
    // transport that returns 200 while dropping headers or sending no body.
    const postP = fetch(`${baseUrl}/post`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        [postRequest.sendHeader]: postRequest.sendHeaderValue,
      },
      body: postRequest.sendBody,
    })
      .then(res => res.text())
      .then(echo => {
        let seen;
        try {
          seen = JSON.parse(echo);
        } catch (e) {
          setPostOk(false);
          return;
        }
        setPostOk(
          seen.method === 'POST' &&
            seen.header === postRequest.sendHeaderValue &&
            seen.body === postRequest.sendBody,
        );
      })
      .catch(() => {});

    // --- ERROR PATH: must REJECT, not hang ---------------------------------
    // Port 1 has nothing on it. A pending-forever promise is an app hang, and
    // a happy-path-only gate cannot tell that from success.
    const errP = fetch('http://127.0.0.1:1/nothing')
      .then(() => setErrorOk(false))
      .catch(() => setErrorOk(true));

    Promise.all([getP, statusP, postP, errP]).then(() => {
      setLabel(`status=${measuredStatus}`);
    });
  }, []);

  return (
    <View
      style={{
        width: surface.width,
        height: surface.height,
        backgroundColor: surface.background,
      }}>
      <Swatch spec={control} ok={controlOk} color={rgb(control.expect)} />
      <Swatch spec={nativeHalf} ok={nativeHalfOk} color={rgb(nativeHalf.expect)} />
      <Swatch spec={getRequest} ok={getOk} color={rgb(getRequest.expect)} />
      <Swatch spec={getStatus} ok={statusOk} color={rgb(getStatus.expect)} />
      <Swatch spec={postRequest} ok={postOk} color={rgb(postRequest.expect)} />
      <Swatch spec={responseHeaders} ok={headersOk} color={rgb(responseHeaders.expect)} />
      <Swatch spec={errorPath} ok={errorOk} color={rgb(errorPath.expect)} />

      {/* Human-readable, so a reviewer looking at the frame can see WHAT the
          server answered rather than only that a square is coloured. */}
      <View style={{position: 'absolute', left: text.x, top: text.y}}>
        <Text style={{fontSize: text.fontSize, color: '#000000'}}>
          {`net ${label}`}
        </Text>
      </View>
    </View>
  );
}

AppRegistry.registerComponent('P10Fixture', () => Fixture);
