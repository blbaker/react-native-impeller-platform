#include "svg/SvgPath.h"

#include <cctype>
#include <cmath>
#include <vector>

namespace rni {

namespace {

class Tokenizer {
 public:
  explicit Tokenizer(const std::string& s) : s_(s), i_(0) {}

  void skipSeparators() {
    while (i_ < s_.size() &&
           (std::isspace((unsigned char)s_[i_]) || s_[i_] == ',')) {
      ++i_;
    }
  }

  bool eof() {
    skipSeparators();
    return i_ >= s_.size();
  }

  // A command letter is any of MmLlHhVvCcSsQqTtAaZz.
  bool peekCommand(char* out) {
    skipSeparators();
    if (i_ >= s_.size()) return false;
    char c = s_[i_];
    if (std::isalpha((unsigned char)c)) {
      *out = c;
      return true;
    }
    return false;
  }

  char nextCommand() {
    skipSeparators();
    return s_[i_++];
  }

  // Numbers may be packed with no separator ("1.5.5" == "1.5 .5") and flags
  // (arc's large-arc/sweep) are single 0/1 digits that may abut the next
  // number with no separator at all ("0108" == flag 0, flag 1, number 08 —
  // handled by the caller reading flags with readFlag(), not readNumber()).
  bool readNumber(double* out) {
    skipSeparators();
    size_t start = i_;
    size_t n = s_.size();
    size_t j = i_;
    if (j < n && (s_[j] == '+' || s_[j] == '-')) ++j;
    bool sawDigitsOrDot = false;
    while (j < n && std::isdigit((unsigned char)s_[j])) { ++j; sawDigitsOrDot = true; }
    if (j < n && s_[j] == '.') {
      ++j;
      while (j < n && std::isdigit((unsigned char)s_[j])) { ++j; sawDigitsOrDot = true; }
    }
    if (!sawDigitsOrDot) return false;
    if (j < n && (s_[j] == 'e' || s_[j] == 'E')) {
      size_t k = j + 1;
      if (k < n && (s_[k] == '+' || s_[k] == '-')) ++k;
      if (k < n && std::isdigit((unsigned char)s_[k])) {
        j = k;
        while (j < n && std::isdigit((unsigned char)s_[j])) ++j;
      }
    }
    *out = std::stod(s_.substr(start, j - start));
    i_ = j;
    return true;
  }

  // Arc flags are exactly one character, '0' or '1', and may not have a
  // separator before the next token — reading them with readNumber() would
  // happily (and wrongly) swallow "10" as ten instead of flag=1, next digit
  // '0'.
  bool readFlag(bool* out) {
    skipSeparators();
    if (i_ >= s_.size()) return false;
    char c = s_[i_];
    if (c != '0' && c != '1') return false;
    *out = (c == '1');
    ++i_;
    return true;
  }

 private:
  const std::string& s_;
  size_t i_;
};

// Endpoint-to-center arc parameterization (SVG 1.1 Appendix F.6.5),
// converted straight to a sequence of cubic Beziers (F.13.1's cubic
// approximation, split at <= 90 degree segments so the approximation error
// stays small).
void ArcToCubics(ImpellerPathBuilder builder, double x0, double y0, double rx,
                  double ry, double xRotDeg, bool largeArc, bool sweep,
                  double x1, double y1) {
  if (rx == 0.0 || ry == 0.0) {
    ImpellerPoint p = {(float)x1, (float)y1};
    ImpellerPathBuilderLineTo(builder, &p);
    return;
  }
  rx = std::fabs(rx);
  ry = std::fabs(ry);
  double phi = xRotDeg * M_PI / 180.0;
  double cosPhi = std::cos(phi), sinPhi = std::sin(phi);

  // Step 1: compute (x1', y1') — midpoint in the rotated frame.
  double dx2 = (x0 - x1) / 2.0, dy2 = (y0 - y1) / 2.0;
  double x1p = cosPhi * dx2 + sinPhi * dy2;
  double y1p = -sinPhi * dx2 + cosPhi * dy2;

  // Step 2: correct out-of-range radii (F.6.6).
  double lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if (lambda > 1.0) {
    double s = std::sqrt(lambda);
    rx *= s;
    ry *= s;
  }

  // Step 3: compute (cx', cy').
  double rxSq = rx * rx, rySq = ry * ry;
  double x1pSq = x1p * x1p, y1pSq = y1p * y1p;
  double num = rxSq * rySq - rxSq * y1pSq - rySq * x1pSq;
  double den = rxSq * y1pSq + rySq * x1pSq;
  double coef = 0.0;
  if (den > 1e-9 && num > 0.0) {
    coef = std::sqrt(num / den);
  }
  if (largeArc == sweep) coef = -coef;
  double cxp = coef * (rx * y1p / ry);
  double cyp = coef * (-ry * x1p / rx);

  // Step 4: (cx, cy) from (cx', cy').
  double cx = cosPhi * cxp - sinPhi * cyp + (x0 + x1) / 2.0;
  double cy = sinPhi * cxp + cosPhi * cyp + (y0 + y1) / 2.0;

  auto angle = [](double ux, double uy, double vx, double vy) -> double {
    double dot = ux * vx + uy * vy;
    double len = std::sqrt(ux * ux + uy * uy) * std::sqrt(vx * vx + vy * vy);
    double a = std::acos(std::max(-1.0, std::min(1.0, dot / len)));
    if (ux * vy - uy * vx < 0.0) a = -a;
    return a;
  };

  double theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
  double dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                        (-x1p - cxp) / rx, (-y1p - cyp) / ry);
  if (!sweep && dtheta > 0) dtheta -= 2 * M_PI;
  if (sweep && dtheta < 0) dtheta += 2 * M_PI;

  // Split into segments of at most 90 degrees for a good cubic approximation.
  int segments = (int)std::ceil(std::fabs(dtheta) / (M_PI / 2.0));
  if (segments < 1) segments = 1;
  double delta = dtheta / segments;
  double t = 4.0 / 3.0 * std::tan(delta / 4.0);

  double theta = theta1;
  for (int i = 0; i < segments; ++i) {
    double c1 = std::cos(theta), s1 = std::sin(theta);
    double theta2 = theta + delta;
    double c2 = std::cos(theta2), s2 = std::sin(theta2);

    // Point + tangent at start and end of this segment, in the unrotated
    // unit-circle frame, then mapped through rotate+scale+translate.
    auto mapPoint = [&](double ex, double ey) -> ImpellerPoint {
      double px = rx * ex, py = ry * ey;
      double rxp = cosPhi * px - sinPhi * py + cx;
      double ryp = sinPhi * px + cosPhi * py + cy;
      return ImpellerPoint{(float)rxp, (float)ryp};
    };

    ImpellerPoint p1 = mapPoint(c1 - t * s1, s1 + t * c1);
    ImpellerPoint p2 = mapPoint(c2 + t * s2, s2 - t * c2);
    ImpellerPoint end = mapPoint(c2, s2);

    ImpellerPathBuilderCubicCurveTo(builder, &p1, &p2, &end);
    theta = theta2;
  }
}

}  // namespace

bool ParseSvgPathToBuilder(const std::string& d, ImpellerPathBuilder builder) {
  Tokenizer tok(d);
  double curX = 0, curY = 0;       // current point
  double startX = 0, startY = 0;   // subpath start, for Z
  double lastCtrlX = 0, lastCtrlY = 0;  // last cubic/quad control point, for S/T
  char lastCmd = 0;   // last command executed, to know if S/T reflection applies
  bool haveSubpath = false;
  bool parsedAny = false;

  auto readXY = [&](double* x, double* y) -> bool {
    return tok.readNumber(x) && tok.readNumber(y);
  };

  while (!tok.eof()) {
    char c;
    if (!tok.peekCommand(&c)) break;  // stray non-command tokens: stop, keep what we have
    c = tok.nextCommand();
    bool relative = std::islower((unsigned char)c);
    char cmd = (char)std::toupper((unsigned char)c);

    // Implicit repetition: after the first coordinate set, further
    // coordinate pairs with no new letter repeat the SAME command — except
    // that a repeated 'M'/'m' becomes an implicit 'L'/'l' (SVG spec).
    bool first = true;
    do {
      switch (cmd) {
        case 'M': {
          double x, y;
          if (!readXY(&x, &y)) goto done;
          if (relative && haveSubpath) { x += curX; y += curY; }
          else if (relative) { x += curX; y += curY; }
          curX = x; curY = y;
          startX = x; startY = y;
          ImpellerPoint p = {(float)x, (float)y};
          ImpellerPathBuilderMoveTo(builder, &p);
          haveSubpath = true;
          parsedAny = true;
          if (!first) { /* stays 'M' semantics only for first pair */ }
          cmd = 'L';  // subsequent implicit pairs are lineto per spec
          break;
        }
        case 'L': {
          double x, y;
          if (!readXY(&x, &y)) goto done;
          if (relative) { x += curX; y += curY; }
          curX = x; curY = y;
          ImpellerPoint p = {(float)x, (float)y};
          ImpellerPathBuilderLineTo(builder, &p);
          parsedAny = true;
          break;
        }
        case 'H': {
          double x;
          if (!tok.readNumber(&x)) goto done;
          if (relative) x += curX;
          curX = x;
          ImpellerPoint p = {(float)x, (float)curY};
          ImpellerPathBuilderLineTo(builder, &p);
          parsedAny = true;
          break;
        }
        case 'V': {
          double y;
          if (!tok.readNumber(&y)) goto done;
          if (relative) y += curY;
          curY = y;
          ImpellerPoint p = {(float)curX, (float)y};
          ImpellerPathBuilderLineTo(builder, &p);
          parsedAny = true;
          break;
        }
        case 'C': {
          double x1, y1, x2, y2, x, y;
          if (!readXY(&x1, &y1) || !readXY(&x2, &y2) || !readXY(&x, &y)) goto done;
          if (relative) { x1 += curX; y1 += curY; x2 += curX; y2 += curY; x += curX; y += curY; }
          ImpellerPoint cp1 = {(float)x1, (float)y1};
          ImpellerPoint cp2 = {(float)x2, (float)y2};
          ImpellerPoint end = {(float)x, (float)y};
          ImpellerPathBuilderCubicCurveTo(builder, &cp1, &cp2, &end);
          lastCtrlX = x2; lastCtrlY = y2;
          curX = x; curY = y;
          parsedAny = true;
          break;
        }
        case 'S': {
          double x2, y2, x, y;
          if (!readXY(&x2, &y2) || !readXY(&x, &y)) goto done;
          if (relative) { x2 += curX; y2 += curY; x += curX; y += curY; }
          double x1, y1;
          if (lastCmd == 'C' || lastCmd == 'S') {
            x1 = 2 * curX - lastCtrlX;
            y1 = 2 * curY - lastCtrlY;
          } else {
            x1 = curX; y1 = curY;
          }
          ImpellerPoint cp1 = {(float)x1, (float)y1};
          ImpellerPoint cp2 = {(float)x2, (float)y2};
          ImpellerPoint end = {(float)x, (float)y};
          ImpellerPathBuilderCubicCurveTo(builder, &cp1, &cp2, &end);
          lastCtrlX = x2; lastCtrlY = y2;
          curX = x; curY = y;
          parsedAny = true;
          break;
        }
        case 'Q': {
          double x1, y1, x, y;
          if (!readXY(&x1, &y1) || !readXY(&x, &y)) goto done;
          if (relative) { x1 += curX; y1 += curY; x += curX; y += curY; }
          ImpellerPoint cp = {(float)x1, (float)y1};
          ImpellerPoint end = {(float)x, (float)y};
          ImpellerPathBuilderQuadraticCurveTo(builder, &cp, &end);
          lastCtrlX = x1; lastCtrlY = y1;
          curX = x; curY = y;
          parsedAny = true;
          break;
        }
        case 'T': {
          double x, y;
          if (!readXY(&x, &y)) goto done;
          if (relative) { x += curX; y += curY; }
          double x1, y1;
          if (lastCmd == 'Q' || lastCmd == 'T') {
            x1 = 2 * curX - lastCtrlX;
            y1 = 2 * curY - lastCtrlY;
          } else {
            x1 = curX; y1 = curY;
          }
          ImpellerPoint cp = {(float)x1, (float)y1};
          ImpellerPoint end = {(float)x, (float)y};
          ImpellerPathBuilderQuadraticCurveTo(builder, &cp, &end);
          lastCtrlX = x1; lastCtrlY = y1;
          curX = x; curY = y;
          parsedAny = true;
          break;
        }
        case 'A': {
          double rx, ry, xrot;
          bool largeArc, sweep;
          double x, y;
          if (!tok.readNumber(&rx) || !tok.readNumber(&ry) ||
              !tok.readNumber(&xrot) || !tok.readFlag(&largeArc) ||
              !tok.readFlag(&sweep) || !readXY(&x, &y)) {
            goto done;
          }
          if (relative) { x += curX; y += curY; }
          ArcToCubics(builder, curX, curY, rx, ry, xrot, largeArc, sweep, x, y);
          curX = x; curY = y;
          parsedAny = true;
          break;
        }
        case 'Z': {
          ImpellerPathBuilderClose(builder);
          curX = startX; curY = startY;
          parsedAny = true;
          break;
        }
        default:
          goto done;
      }
      lastCmd = cmd;
      first = false;
      // Loop again only if more numeric tokens follow with no new command
      // letter (implicit repetition) — but not for Z, which takes no args.
    } while (cmd != 'Z' && !tok.eof() && !tok.peekCommand(&c));
  }
done:
  return parsedAny;
}

}  // namespace rni
