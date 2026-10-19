// SINGLE SOURCE OF TRUTH for the iOS input fixture geometry, in points. index.js
// renders from it and tools/ci-ios-input.sh taps from it (the JSON object after
// `module.exports =`). Everything sits below y=150 (Dynamic Island) and above
// y=420, so the software keyboard never covers a target.
module.exports = {
  "background": "#ffffff",
  "button": {"x": 40, "y": 180, "width": 160, "height": 80, "color": "#ff0000",
             "pressedColor": "#00aa00"},
  "input": {"x": 40, "y": 300, "width": 300, "height": 50, "color": "#eeeeee"},
  "typed": "hi rn"
};
