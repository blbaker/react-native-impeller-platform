#pragma once

// FP-52: numbers out of folly::dynamic prop values, without throwing or UB.
// folly's asDouble() THROWS ConversionError for an int64 a double cannot hold
// exactly (2^53 + 1), and JSI hands whole JS numbers over as int64, so
// `opacity: 2**60` from JS used to terminate the JS thread (fuzz seed
// scene/crash-asdouble-int64). Casting an out-of-range or NaN double to an
// integer is UB, hence ClampTo.

#include <folly/dynamic.h>

#include <cmath>
#include <limits>

namespace rni {

// By value, never by storage class. Non-numbers read as 0.
inline double NumberOf(const folly::dynamic& v) {
  if (v.isInt()) return (double)v.getInt();
  return v.isDouble() ? v.getDouble() : 0.0;
}

// Saturating integer conversion; NaN -> 0.
template <typename I>
I ClampTo(double d) {
  if (!(d == d)) return 0;
  if (d <= (double)std::numeric_limits<I>::min()) return std::numeric_limits<I>::min();
  if (d >= (double)std::numeric_limits<I>::max()) return std::numeric_limits<I>::max();
  return (I)d;
}

}  // namespace rni
