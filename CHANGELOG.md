# Changelog

## [0.3.0](https://github.com/blbaker/react-native-impeller-platform/compare/v0.2.0...v0.3.0) (2026-10-19)


### Features

* **engine:** add a Notifications module for desktop notifications ([0e97d2a](https://github.com/blbaker/react-native-impeller-platform/commit/0e97d2afd31fc17f011b28cc0458853ae743772d))
* **engine:** add a Notifications module for desktop notifications ([5c99dfd](https://github.com/blbaker/react-native-impeller-platform/commit/5c99dfd6328a14791b93b72c9b2378f7f1c27370))
* **ios:** touch and system keyboard input for RNIEngine ([02deacb](https://github.com/blbaker/react-native-impeller-platform/commit/02deacb860b8406c51df7a740ceccb185efae304))
* **ios:** touch and system keyboard input, tested with real UIKit input ([17e2945](https://github.com/blbaker/react-native-impeller-platform/commit/17e29458ad6a4705e87a77c0e20fe055436231dc))


### Bug Fixes

* **engine:** keep the Windows toast objects on one COM thread ([2814df8](https://github.com/blbaker/react-native-impeller-platform/commit/2814df8421927868baf2032cf5f40958cc1bd4c7))

## [0.2.0](https://github.com/blbaker/react-native-impeller-platform/compare/v0.1.0...v0.2.0) (2026-10-19)


### Features

* **ios:** iOS branch of engine/CMakeLists.txt, Hermes for iOS, docs ([74c8a35](https://github.com/blbaker/react-native-impeller-platform/commit/74c8a3534be9fbaa602aec6ad4c3e977384f7116))
* **ios:** iOS surface primitives with simulator gates ([a92e1ee](https://github.com/blbaker/react-native-impeller-platform/commit/a92e1eeb2967bb84d055156cb80795ff0d27e78d))
* **ios:** iOS surface primitives with simulator gates ([14c96c1](https://github.com/blbaker/react-native-impeller-platform/commit/14c96c1dad53d643e1c38636bf1aab9046380f16))
* **ios:** the engine for iOS and RNIEngine, its host API ([365f65f](https://github.com/blbaker/react-native-impeller-platform/commit/365f65ffc6c84917d08bf8e5211d3d0548ee3eaf))
* **ios:** the engine on iOS, RNIEngine, and M1 in the simulator ([0a65221](https://github.com/blbaker/react-native-impeller-platform/commit/0a652214068bf71b6e194bf47e26f0ee1f96ffd2))
* publish the Android custom Impeller SDK and fetch it ([8a67bd2](https://github.com/blbaker/react-native-impeller-platform/commit/8a67bd2a16f206b712e808ee921ca73ff149c161))


### Bug Fixes

* compile ResizeProbe.cpp unconditionally ([71038f2](https://github.com/blbaker/react-native-impeller-platform/commit/71038f2ceb757e0190118f16ad1abc4ca4a8b3e9))
* **darwin:** load the engine's dylibs through [@rpath](https://github.com/rpath) so a standard .app runs it ([4f01a09](https://github.com/blbaker/react-native-impeller-platform/commit/4f01a09c6265b8b33396b18fedc99bad64c5ac99))
* **darwin:** load the engine's dylibs through [@rpath](https://github.com/rpath) so a standard .app runs it ([6ff1967](https://github.com/blbaker/react-native-impeller-platform/commit/6ff1967d5d63ec515009bc3c51fa8be3e55662b6))
* **darwin:** ship Hermes as a flat libhermesvm.dylib ([e21fdd2](https://github.com/blbaker/react-native-impeller-platform/commit/e21fdd2e41c3d2f729e06fb948fcaded59c3730c))
* **darwin:** ship Hermes as a flat libhermesvm.dylib ([71fc7dd](https://github.com/blbaker/react-native-impeller-platform/commit/71fc7ddec25e798271da3cb52fbe332801589a87))

## [0.1.0](https://github.com/blbaker/react-native-impeller-platform/compare/v0.0.1...v0.1.0) (2026-10-17)


### ⚠ BREAKING CHANGES

* install react-native-impeller-platform instead of @react-native-impeller/core. Nothing was published under the old names.

### Features

* add Release Please config and the open-source readiness audit ([f8b08be](https://github.com/blbaker/react-native-impeller-platform/commit/f8b08be8a3d211b1fd2272276c0f5c02f29c4b75))
* **ENG-31:** globalThis.crypto.getRandomValues on the OS CSPRNG ([e89d023](https://github.com/blbaker/react-native-impeller-platform/commit/e89d0232336a5e2af96849dcd315406ec7a7b101))
* **expo-host:** vend ExponentConstants and ExpoFetchModule (SC-44) ([51a6032](https://github.com/blbaker/react-native-impeller-platform/commit/51a6032f34e95780c29611761fb83537f68c9d01))
* publish as react-native-impeller-platform ([5a7419e](https://github.com/blbaker/react-native-impeller-platform/commit/5a7419ed11086324cf5399225f3cdf2ae483cff5))


### Bug Fixes

* **build:** fetch the custom Impeller SDK instead of falling back to stock ([2e36857](https://github.com/blbaker/react-native-impeller-platform/commit/2e36857bf8399c9aa84ed246f98cf3520be989c4))
* **ci:** fetch GLFW on a fresh checkout ([8f1bba7](https://github.com/blbaker/react-native-impeller-platform/commit/8f1bba782fd7a587bae776c69e7ce632cf0c5fd5))
* **ci:** fetch GLFW, and build the engines before any publish ([c31fe57](https://github.com/blbaker/react-native-impeller-platform/commit/c31fe57cc4c6f565928c686bca59f2b81410d67e))
* **ci:** give the text gates the font they were measured with ([44c4f66](https://github.com/blbaker/react-native-impeller-platform/commit/44c4f66f52e12504f3355198374df3d8936652ea))
* **ci:** install the Ubuntu font the text gates were measured with ([1036210](https://github.com/blbaker/react-native-impeller-platform/commit/10362103ae9186db770341d87b4986c99a2a16c4))
* **merge:** build lane A's FP-42/43/44 sources into rni-scenegraph-tests ([0357898](https://github.com/blbaker/react-native-impeller-platform/commit/035789882f535b3da6569c44216520455ecdbbe9))
* **win:** don't link whatever OpenSSL the build machine has ([3e40417](https://github.com/blbaker/react-native-impeller-platform/commit/3e404171d9991e3a7995362018bdf21b11a1a266))
* **win:** include &lt;mutex&gt; where React Native's HostTarget.h uses std::mutex ([ae1b0b0](https://github.com/blbaker/react-native-impeller-platform/commit/ae1b0b0d75094fef0f506dc4e6f4eef949793ede))
