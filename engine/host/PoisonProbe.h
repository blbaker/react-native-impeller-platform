// FP-17 test hook for ci-image-upload: RNI_TEST_POISON_PROBE=1 reads every
// windowed present back (raster thread, before the present) and counts presents
// that show the IO upload's poison colour (magenta, written only while
// RNI_TEST_IO_UPLOAD_DELAY_MS holds a transfer open). A texture handed to the
// raster thread before its fence shows poison. Prints at exit:
//   poison_probe presents= poisoned= max_px= first=
#pragma once

#include "host/Pixel.h"

#include <vector>

namespace rni::poisonprobe {

bool Enabled();
void OnPresent(const std::vector<Px>& px, int width, int height, int present);
void PrintSummary();  // no-op when disabled

}  // namespace rni::poisonprobe
