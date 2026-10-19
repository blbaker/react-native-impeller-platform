// SINGLE SOURCE OF TRUTH for the iOS M1 fixture geometry, in points. index.js
// renders from it and tools/ci-ios-sim.sh probes from it (the checker reads
// the JSON object after `module.exports =`), so the two cannot drift.
// Colors are exact sRGB with no alpha, so a probe expects the literal bytes.
// Everything sits below y=150: the top of an iPhone screen is the Dynamic Island.
module.exports = {
  "background": "#ffffff",
  "boxes": [
    {"id": "plain", "x": 40, "y": 200, "width": 120, "height": 80, "color": "#ff0000"},
    {"id": "rounded", "x": 200, "y": 200, "width": 150, "height": 100, "radius": 24,
     "color": "#0000ff"},
    {"id": "nested", "x": 40, "y": 400, "width": 200, "height": 150, "color": "#00aa00",
     "child": {"id": "child", "x": 20, "y": 20, "width": 60, "height": 40, "color": "#ffcc00"}}
  ],
  "label": {"text": "iOS M1", "x": 40, "y": 620, "fontSize": 28, "color": "#000000",
            "inkBand": [40, 615, 220, 50]}
};
