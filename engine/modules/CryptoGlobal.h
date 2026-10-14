// CryptoGlobal — `globalThis.crypto.getRandomValues` backed by the OS CSPRNG
// (ENG-31).
//
// WHY. Hermes ships no `crypto`, and RN installs none, so on this host
// `typeof crypto` was "undefined" (Mac probe, darwin sha ff6bd407). Code
// that needs real entropy (the HostApp relay's NaCl box keys + nonces, uuid v4,
// tweetnacl's auto PRNG detection) had nothing to call. Math.random is not a
// substitute: it is a seeded PRNG and its output is predictable.
//
// CONTRACT (WebCrypto, Crypto.getRandomValues):
//   - argument: an INTEGER TypedArray (Int8/Uint8/Uint8Clamped/Int16/Uint16/
//     Int32/Uint32/BigInt64/BigUint64Array). Float arrays and DataView throw
//     TypeMismatchError; a non-view throws TypeError.
//   - byteLength > 65536 throws QuotaExceededError and leaves the array as is.
//   - fills exactly the view's bytes (byteOffset..byteOffset+byteLength of its
//     buffer) and returns the SAME array.
//   - reading `crypto` never throws.
//
// SOURCE OF BYTES (fillRandomBytes in the .cpp):
//   darwin / android  arc4random_buf  (kernel-seeded ChaCha20, cannot fail)
//   linux             getrandom(2)    (blocks only until the pool is seeded)
//   windows           BCryptGenRandom (system-preferred RNG)
//
// SPLIT. Validation is JS that captures the %TypedArray% intrinsic getters
// (buffer, byteOffset, byteLength, @@toStringTag) ONCE at install, so an
// object that fakes those as own properties is refused and later prototype
// tampering changes nothing. The native half only writes CSPRNG bytes into an
// ArrayBuffer range it bounds-checks again itself.
#pragma once

#include <jsi/jsi.h>

#include <cstddef>
#include <cstdint>

namespace rni {

// Fill `out` with `len` bytes from the OS CSPRNG. False only if the OS refused
// (getrandom/BCrypt error); the caller must then fail, never fall back.
bool fillRandomBytes(uint8_t* out, size_t len);

// Install globalThis.crypto = { getRandomValues }. Call once per runtime,
// before the bundle runs (ReactHost's bindings install).
void installCryptoGlobal(facebook::jsi::Runtime& runtime);

}  // namespace rni
