#include <react/renderer/graphics/PlatformColorTable.h>

namespace facebook::react::impeller_platform_color {

static const Entry* table(size_t& count) {
  static const Entry kTable[] = {
      {"systemRed", {255, 59, 48, 1}, {255, 69, 58, 1}},
      {"systemOrange", {255, 149, 0, 1}, {255, 159, 10, 1}},
      {"systemYellow", {255, 204, 0, 1}, {255, 214, 10, 1}},
      {"systemGreen", {52, 199, 89, 1}, {48, 209, 88, 1}},
      {"systemMint", {0, 199, 190, 1}, {99, 230, 226, 1}},
      {"systemTeal", {48, 176, 199, 1}, {64, 200, 224, 1}},
      {"systemCyan", {50, 173, 230, 1}, {100, 210, 255, 1}},
      {"systemBlue", {0, 122, 255, 1}, {10, 132, 255, 1}},
      {"systemIndigo", {88, 86, 214, 1}, {94, 92, 230, 1}},
      {"systemPurple", {175, 82, 222, 1}, {191, 90, 242, 1}},
      {"systemPink", {255, 45, 85, 1}, {255, 55, 95, 1}},
      {"systemBrown", {162, 132, 94, 1}, {172, 142, 104, 1}},
      {"systemGray", {142, 142, 147, 1}, {142, 142, 147, 1}},
      {"systemGray2", {174, 174, 178, 1}, {99, 99, 102, 1}},
      {"systemGray3", {199, 199, 204, 1}, {72, 72, 74, 1}},
      {"systemGray4", {209, 209, 214, 1}, {58, 58, 60, 1}},
      {"systemGray5", {229, 229, 234, 1}, {44, 44, 46, 1}},
      {"systemGray6", {242, 242, 247, 1}, {28, 28, 30, 1}},
      {"tintColor", {0, 122, 255, 1}, {10, 132, 255, 1}},
      {"label", {0, 0, 0, 1}, {255, 255, 255, 1}},
      {"secondaryLabel", {60, 60, 67, 0.6f}, {235, 235, 245, 0.6f}},
      {"tertiaryLabel", {60, 60, 67, 0.3f}, {235, 235, 245, 0.3f}},
      {"quaternaryLabel", {60, 60, 67, 0.18f}, {235, 235, 245, 0.16f}},
      {"placeholderText", {60, 60, 67, 0.3f}, {235, 235, 245, 0.3f}},
      {"link", {0, 122, 255, 1}, {9, 158, 255, 1}},
      {"separator", {60, 60, 67, 0.29f}, {84, 84, 88, 0.6f}},
      {"opaqueSeparator", {198, 198, 200, 1}, {56, 56, 58, 1}},
      {"systemBackground", {255, 255, 255, 1}, {0, 0, 0, 1}},
      {"secondarySystemBackground", {242, 242, 247, 1}, {28, 28, 30, 1}},
      {"tertiarySystemBackground", {255, 255, 255, 1}, {44, 44, 46, 1}},
      {"systemGroupedBackground", {242, 242, 247, 1}, {0, 0, 0, 1}},
      {"secondarySystemGroupedBackground", {255, 255, 255, 1}, {28, 28, 30, 1}},
      {"tertiarySystemGroupedBackground", {242, 242, 247, 1}, {44, 44, 46, 1}},
      {"systemFill", {120, 120, 128, 0.2f}, {120, 120, 128, 0.36f}},
      {"secondarySystemFill", {120, 120, 128, 0.16f}, {120, 120, 128, 0.32f}},
      {"tertiarySystemFill", {118, 118, 128, 0.12f}, {118, 118, 128, 0.24f}},
      {"quaternarySystemFill", {116, 116, 128, 0.08f}, {118, 118, 128, 0.18f}},
      {"lightText", {255, 255, 255, 0.6f}, {255, 255, 255, 0.6f}},
      {"darkText", {0, 0, 0, 0.85f}, {0, 0, 0, 0.85f}},
      // Android names: attr/ and android:color/ with the prefix stripped.
      {"colorAccent", {0, 122, 255, 1}, {10, 132, 255, 1}},
      {"colorPrimary", {98, 0, 238, 1}, {187, 134, 252, 1}},
      {"textColorPrimary", {0, 0, 0, 0.87f}, {255, 255, 255, 1}},
      {"textColorSecondary", {0, 0, 0, 0.54f}, {255, 255, 255, 0.7f}},
      {"colorBackground", {255, 255, 255, 1}, {0, 0, 0, 1}},
      {"white", {255, 255, 255, 1}, {255, 255, 255, 1}},
      {"black", {0, 0, 0, 1}, {0, 0, 0, 1}},
      {"transparent", {0, 0, 0, 0}, {0, 0, 0, 0}},
      {"holo_blue_light", {51, 181, 229, 1}, {51, 181, 229, 1}},
      {"holo_red_light", {255, 68, 68, 1}, {255, 68, 68, 1}},
      {"holo_green_light", {153, 204, 0, 1}, {153, 204, 0, 1}},
  };
  count = sizeof(kTable) / sizeof(kTable[0]);
  return kTable;
}

// Accepts 'systemBlue', 'systemBlueColor' (ObjC selector spelling), '?attr/x',
// '?android:attr/x', '@android:color/x' and '@color/x'. Returns null if unknown.
const Entry* find(const std::string& raw) {
  std::string name = raw;
  auto slash = name.rfind('/');
  if (slash != std::string::npos) name = name.substr(slash + 1);
  size_t count = 0;
  const Entry* entries = table(count);
  for (int pass = 0; pass < 2; ++pass) {
    for (size_t i = 0; i < count; ++i) {
      if (name == entries[i].name) return &entries[i];
    }
    if (name.size() > 5 && name.compare(name.size() - 5, 5, "Color") == 0) {
      name.resize(name.size() - 5);
    } else {
      break;
    }
  }
  return nullptr;
}

} // namespace facebook::react::impeller_platform_color
