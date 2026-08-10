/**
 * P4 module-seam fixture — NOT a demo app.
 *
 * THE DESIGN RULE, INHERITED FROM P2/P3: a module's result must become a
 * PIXEL. It would be far easier to console.log what each TurboModule returned
 * and grep the log — and it would be worth nothing, because a log line proves
 * the JS ran, not that the value was right, and stdout ordering has already
 * burned this project once (a log counter scored the same working build 1/6,
 * 4/8 and 0/4).
 *
 * So each module gets a swatch that is painted ONLY when that module returned
 * the expected value. A module that is absent, unreachable through the
 * bridgeless binding, or quietly returning its default leaves BACKGROUND at
 * that probe, and the gate reads the framebuffer.
 *
 * Every assertion is against a NON-DEFAULT value where one exists. Asserting
 * `colorScheme === 'light'` would pass with no Appearance module at all,
 * because that is RN's fallback — so the engine is launched with
 * `--color-scheme dark` and the fixture demands dark.
 */
import React from 'react';
import {
  Alert,
  Appearance,
  AppRegistry,
  Linking,
  NativeModules,
  Platform,
  StatusBar,
  Text,
  View,
} from 'react-native';
import geometry from './fixture.json';

const {
  surface,
  swatchSize,
  appearance,
  statusBar,
  alert,
  linking,
  initialUrl,
  devSettings,
  defaults,
  platformConstants,
  text,
} = geometry;

function Swatch({spec, ok, color}) {
  // Not rendering at all when !ok would leave the node out of the tree, and
  // "node missing" and "node painted the wrong colour" are different bugs. The
  // node always exists; only its colour carries the verdict.
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
  // --- Appearance: must equal the scheme the ENGINE was told to report ------
  const scheme = Appearance.getColorScheme();
  const appearanceOk = scheme === appearance.expectScheme;

  // --- StatusBarManager: reaching its constants at all is the assertion, ----
  // because NativeStatusBarManagerIOS.js getEnforcing's the module and the
  // whole bundle throws at import if it is missing.
  let statusBarOk = false;
  try {
    const sbm = NativeModules.StatusBarManager;
    statusBarOk = sbm != null && typeof sbm.getConstants === 'function' &&
      sbm.getConstants().HEIGHT === 0;
    // Touch the JS API too, so a broken setter surfaces here rather than in an
    // app later.
    StatusBar.setHidden(false);
  } catch (e) {
    statusBarOk = false;
  }

  // --- DevSettings: also getEnforcing'd; a no-op call must not throw --------
  let devSettingsOk = false;
  try {
    NativeModules.DevSettings.setHotLoadingEnabled(false);
    devSettingsOk = true;
  } catch (e) {
    devSettingsOk = false;
  }

  // --- Performance: vended by RN's DefaultTurboModules, not by our registry -
  // This is the delegation assertion. P2 hand-rolled three default modules by
  // name and was silently missing this one entirely.
  let defaultsOk = false;
  try {
    defaultsOk =
      typeof global.performance?.now === 'function' &&
      global.performance.now() > 0;
  } catch (e) {
    defaultsOk = false;
  }

  // --- Platform.constants must come FROM the native module ------------------
  // Asserting the RN minor the ENGINE was compiled against: a JS-side fake
  // could not know it, and the shim returned {} for two phases while the
  // native module answered correctly.
  let platformConstantsOk = false;
  try {
    platformConstantsOk =
      Platform.constants?.reactNativeVersion?.minor === platformConstants.expectMinor;
  } catch (e) {
    platformConstantsOk = false;
  }

  // --- Async results land in state, so the swatch reflects the RESOLVED -----
  // value rather than a promise object.
  const [alertOk, setAlertOk] = React.useState(false);
  const [linkingOk, setLinkingOk] = React.useState(false);
  const [initialUrlOk, setInitialUrlOk] = React.useState(false);

  React.useEffect(() => {
    // The callback firing is the assertion: a module that recorded the alert
    // and never called back would leave the promise inside Alert.js pending
    // forever, which presents as a hang rather than a missing feature.
    Alert.alert('P4', 'module seam', [
      {text: 'OK', onPress: () => setAlertOk(true)},
    ]);

    // BOTH directions. A predicate hardwired to true is exactly as broken as
    // one hardwired to false, and asserting only the happy case cannot see it.
    Promise.all([
      Linking.canOpenURL(linking.okUrl),
      Linking.canOpenURL(linking.refuseUrl),
    ]).then(([allowed, refused]) => {
      setLinkingOk(allowed === true && refused === false);
    });

    Linking.getInitialURL().then(url => {
      setInitialUrlOk(url === initialUrl.value);
    });
  }, []);

  return (
    <View
      style={{
        width: surface.width,
        height: surface.height,
        backgroundColor: surface.background,
      }}>
      <Swatch spec={appearance} ok={appearanceOk} color={rgb(appearance.expect)} />
      <Swatch spec={statusBar} ok={statusBarOk} color={rgb(statusBar.expect)} />
      <Swatch spec={alert} ok={alertOk} color={rgb(alert.expect)} />
      <Swatch spec={linking} ok={linkingOk} color={rgb(linking.expect)} />
      <Swatch spec={initialUrl} ok={initialUrlOk} color={rgb(initialUrl.expect)} />
      <Swatch spec={devSettings} ok={devSettingsOk} color={rgb(devSettings.expect)} />
      <Swatch spec={defaults} ok={defaultsOk} color={rgb(defaults.expect)} />
      <Swatch spec={platformConstants} ok={platformConstantsOk} color={rgb(platformConstants.expect)} />

      {/* Human-readable, so a reviewer looking at the frame can see WHICH
          scheme was reported rather than only that a square is green. */}
      <View style={{position: 'absolute', left: text.x, top: text.y}}>
        <Text style={{fontSize: text.fontSize, color: '#000000'}}>
          {`colorScheme=${String(scheme)}`}
        </Text>
      </View>
    </View>
  );
}

AppRegistry.registerComponent('P4Fixture', () => Fixture);
