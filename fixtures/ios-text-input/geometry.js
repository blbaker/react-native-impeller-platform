// SINGLE SOURCE OF TRUTH for the iOS text-input fixture, in points. index.js
// renders from it and tools/ci-ios-text-input.sh taps and checks from it (the
// JSON object after `module.exports =`). Both fields sit below y=150 (Dynamic
// Island) and above the keyboard. Romaji "nn" is ん: a single trailing "n"
// stays a Latin n when the composition is confirmed (measured: "にほn").
module.exports = {
  "background": "#ffffff",
  "auto": {"x": 40, "y": 180, "width": 300, "height": 50, "color": "#eeeeee",
           "typed": "teh ", "want": "the "},
  "off": {"x": 40, "y": 250, "width": 300, "height": 50, "color": "#f4eee6",
          "typed": "teh ", "want": "teh "},
  "ja": {"x": 40, "y": 320, "width": 300, "height": 50, "color": "#e6f0ff",
         "typed": "nihonn", "want": "にほん"}
};
