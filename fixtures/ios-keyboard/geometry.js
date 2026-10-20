// SINGLE SOURCE OF TRUTH for the iOS keyboard fixture, in points. index.js
// renders from it and tools/ci-ios-keyboard.sh checks from it (the JSON object
// after `module.exports =`). The TextInput and the footer sit at the bottom
// of a KeyboardAvoidingView, exactly where the keyboard comes up.
module.exports = {
  "background": "#ffffff",
  "input": {"height": 50, "color": "#dddddd"},
  "footer": {"height": 60, "color": "#00aa00"}
};
