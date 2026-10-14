// CryptoGlobal — see CryptoGlobal.h for the contract and the WHY.
#include "modules/CryptoGlobal.h"

#include <cerrno>
#include <cmath>
#include <memory>
#include <string>

#if defined(__APPLE__) || defined(__ANDROID__)
#include <stdlib.h>  // arc4random_buf
#elif defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")
#else
#include <sys/random.h>  // getrandom (glibc >= 2.25)
#endif

namespace rni {

namespace jsi = facebook::jsi;

namespace {

// WebCrypto's per-call cap. The JS half refuses more with QuotaExceededError
// before native is reached; native re-checks so no caller can ask for more.
constexpr double kQuotaBytes = 65536;

// Captures the %TypedArray% intrinsics once, then returns nothing: it defines
// globalThis.crypto itself. `fill` is the native writer, passed in so it is
// never reachable from the global object.
const char* kCryptoJs = R"JS(
(function (g, fill) {
  'use strict';
  if (g.crypto && typeof g.crypto.getRandomValues === 'function') return;
  var TA = Object.getPrototypeOf(Uint8Array.prototype);
  var gd = Object.getOwnPropertyDescriptor;
  var getBuffer = gd(TA, 'buffer').get;
  var getOffset = gd(TA, 'byteOffset').get;
  var getLength = gd(TA, 'byteLength').get;
  var getTag = gd(TA, Symbol.toStringTag).get;
  var apply = Reflect.apply;
  var isView = ArrayBuffer.isView;
  var QUOTA = 65536;
  var INTEGER = Object.create(null);
  ['Int8Array', 'Uint8Array', 'Uint8ClampedArray', 'Int16Array', 'Uint16Array',
   'Int32Array', 'Uint32Array', 'BigInt64Array', 'BigUint64Array'
  ].forEach(function (n) { INTEGER[n] = true; });
  var PRE = "Failed to execute 'getRandomValues' on 'Crypto': ";
  function domError(name, code, message) {
    var e = new Error(PRE + message);
    e.name = name;
    e.code = code;
    return e;
  }
  function getRandomValues(array) {
    if (arguments.length < 1) {
      throw new TypeError(PRE + '1 argument required, but only 0 present.');
    }
    // The intrinsic @@toStringTag getter answers only for a REAL TypedArray
    // (undefined for anything else, including an object that fakes the tag
    // or the buffer/byteOffset/byteLength properties as its own).
    var tag = apply(getTag, array, []);
    if (tag === undefined) {
      if (array !== null && typeof array === 'object' && apply(isView, ArrayBuffer, [array])) {
        throw domError('TypeMismatchError', 17,
          'The provided ArrayBufferView is not an integer array type.');
      }
      throw new TypeError(PRE + "parameter 1 is not of type 'ArrayBufferView'.");
    }
    if (INTEGER[tag] !== true) {
      throw domError('TypeMismatchError', 17, "The provided ArrayBufferView is of type '" +
        tag + "', which is not an integer array type.");
    }
    var len = apply(getLength, array, []);
    if (len > QUOTA) {
      throw domError('QuotaExceededError', 22, "The ArrayBufferView's byte length (" + len +
        ') exceeds the number of bytes of entropy available via this API (' + QUOTA + ').');
    }
    if (len > 0) fill(apply(getBuffer, array, []), apply(getOffset, array, []), len);
    return array;
  }
  var c = {};
  Object.defineProperty(c, 'getRandomValues',
    { value: getRandomValues, writable: true, enumerable: true, configurable: true });
  Object.defineProperty(c, Symbol.toStringTag, { value: 'Crypto', configurable: true });
  Object.defineProperty(g, 'crypto',
    { value: c, writable: true, enumerable: false, configurable: true });
})
)JS";

bool isWholeNonNegative(double v) {
  return v >= 0 && std::isfinite(v) && std::floor(v) == v;
}

jsi::Value nativeFill(jsi::Runtime& rt, const jsi::Value&, const jsi::Value* args,
                      size_t count) {
  if (count != 3 || !args[0].isObject() || !args[1].isNumber() || !args[2].isNumber()) {
    throw jsi::JSError(rt, "crypto.getRandomValues: internal fill got bad arguments");
  }
  jsi::Object obj = args[0].getObject(rt);
  if (!obj.isArrayBuffer(rt)) {
    throw jsi::JSError(rt, "crypto.getRandomValues: internal fill got no ArrayBuffer");
  }
  const double off = args[1].getNumber();
  const double len = args[2].getNumber();
  if (!isWholeNonNegative(off) || !isWholeNonNegative(len) || len > kQuotaBytes) {
    throw jsi::JSError(rt, "crypto.getRandomValues: internal fill got a bad range");
  }
  jsi::ArrayBuffer ab = obj.getArrayBuffer(rt);
  const size_t size = ab.size(rt);
  const auto o = static_cast<size_t>(off);
  const auto n = static_cast<size_t>(len);
  if (o > size || n > size - o) {
    throw jsi::JSError(rt, "crypto.getRandomValues: range outside the ArrayBuffer");
  }
  if (n == 0) return jsi::Value::undefined();
  uint8_t* data = ab.data(rt);
  if (data == nullptr) {
    throw jsi::JSError(rt, "crypto.getRandomValues: ArrayBuffer has no storage");
  }
  if (!fillRandomBytes(data + o, n)) {
    // Never hand back non-random bytes: an exception is the only safe answer.
    throw jsi::JSError(rt, "crypto.getRandomValues: the OS random source failed");
  }
  return jsi::Value::undefined();
}

}  // namespace

bool fillRandomBytes(uint8_t* out, size_t len) {
  if (len == 0) return true;
  if (out == nullptr) return false;
#if defined(__APPLE__) || defined(__ANDROID__)
  arc4random_buf(out, len);
  return true;
#elif defined(_WIN32)
  return BCryptGenRandom(nullptr, out, static_cast<ULONG>(len),
                         BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0;
#else
  while (len > 0) {
    const ssize_t got = getrandom(out, len, 0);
    if (got < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    out += got;
    len -= static_cast<size_t>(got);
  }
  return true;
#endif
}

void installCryptoGlobal(jsi::Runtime& runtime) {
  jsi::Value factory = runtime.evaluateJavaScript(
      std::make_shared<jsi::StringBuffer>(kCryptoJs), "rni-crypto.js");
  auto fill = jsi::Function::createFromHostFunction(
      runtime, jsi::PropNameID::forAscii(runtime, "fill"), 3, nativeFill);
  factory.asObject(runtime).asFunction(runtime).call(runtime, runtime.global(), fill);
}

}  // namespace rni
