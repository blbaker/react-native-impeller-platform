// FP-24 swapchain probe: a NativeActivity that draws through the real
// rni::AndroidVkSurface and rotates itself on KEYCODE_SPACE, so
// tools/ci-android-swapchain.sh can resize one live ANativeWindow 20 times.
//
// Each frame: a per-cycle background colour (a frozen frame shows the previous
// cycle's colour) and a white kSquare x kSquare px square at the drawable's
// centre (a stale-sized swapchain is scaled by the compositor, so the square
// stops being square on screen). Logs, tag rn-impeller:
//   probe_cycle n=N orientation=portrait|landscape
//   probe_ready cycle=N win=WxH drawable=WxH presents=P resizes=R recreates=C failures=F
//   probe_stuck cycle=N win=WxH drawable=WxH ...   (60 presents without a match)

#include <android/log.h>
#include <android/window.h>
#include <android_native_app_glue.h>
#include <jni.h>

#include "host/AndroidVkSurface.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "rn-impeller", __VA_ARGS__)

namespace {

constexpr float kSquare = 300.0f;
constexpr int kReadyPresents = 3;
constexpr int kStuckPresents = 60;
// Must match tools/ci-android-swapchain.sh PALETTE.
constexpr float kPalette[][3] = {
    {0.80f, 0.10f, 0.10f}, {0.10f, 0.70f, 0.15f}, {0.10f, 0.25f, 0.85f},
    {0.85f, 0.75f, 0.10f}, {0.60f, 0.15f, 0.75f}, {0.10f, 0.70f, 0.75f}};
constexpr int kPaletteSize = sizeof(kPalette) / sizeof(kPalette[0]);

// android.content.pm.ActivityInfo.SCREEN_ORIENTATION_*
constexpr int kLandscape = 0;
constexpr int kPortrait = 1;

struct Probe {
  rni::AndroidVkSurface surface;
  int cycle = 0;
  int stable_presents = 0;  // presents since cycle / window / drawable changed
  int last_win_w = 0, last_win_h = 0, last_dw = 0, last_dh = 0;
  bool reported = false;
  int total_presents = 0;
};

void SetOrientation(android_app* app, int orientation) {
  JNIEnv* env = nullptr;
  app->activity->vm->AttachCurrentThread(&env, nullptr);
  jclass cls = env->GetObjectClass(app->activity->clazz);
  jmethodID set = env->GetMethodID(cls, "setRequestedOrientation", "(I)V");
  env->CallVoidMethod(app->activity->clazz, set, orientation);
  env->DeleteLocalRef(cls);
  app->activity->vm->DetachCurrentThread();
}

void DrawFrame(Probe& p) {
  if (!p.surface.valid()) return;
  ImpellerSurface target = p.surface.AcquireNext();
  if (target == nullptr) return;
  const auto& st = p.surface.stats();
  const float w = static_cast<float>(st.drawable_width);
  const float h = static_cast<float>(st.drawable_height);

  ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
  const float* bg = kPalette[p.cycle % kPaletteSize];
  ImpellerPaint fill = ImpellerPaintNew();
  ImpellerColor bg_colour = {bg[0], bg[1], bg[2], 1.0f};
  ImpellerPaintSetColor(fill, &bg_colour);
  ImpellerDisplayListBuilderDrawPaint(builder, fill);
  ImpellerPaint square = ImpellerPaintNew();
  ImpellerColor white = {1.0f, 1.0f, 1.0f, 1.0f};
  ImpellerPaintSetColor(square, &white);
  ImpellerRect r = {w / 2 - kSquare / 2, h / 2 - kSquare / 2, kSquare, kSquare};
  ImpellerDisplayListBuilderDrawRect(builder, &r, square);
  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
  if (dl != nullptr) {
    ImpellerSurfaceDrawDisplayList(target, dl);
    ImpellerDisplayListRelease(dl);
  }
  p.surface.Present(target);
  ImpellerPaintRelease(square);
  ImpellerPaintRelease(fill);
  ImpellerDisplayListBuilderRelease(builder);
  p.total_presents++;

  const int ww = p.surface.width(), wh = p.surface.height();
  if (ww != p.last_win_w || wh != p.last_win_h ||
      st.drawable_width != p.last_dw || st.drawable_height != p.last_dh) {
    p.last_win_w = ww; p.last_win_h = wh;
    p.last_dw = st.drawable_width; p.last_dh = st.drawable_height;
    p.stable_presents = 0;
    p.reported = false;
  }
  p.stable_presents++;
  if (p.reported) return;
  const bool match = ww == st.drawable_width && wh == st.drawable_height;
  const char* verdict = nullptr;
  if (match && p.stable_presents >= kReadyPresents) verdict = "probe_ready";
  if (!match && p.stable_presents >= kStuckPresents) verdict = "probe_stuck";
  if (verdict == nullptr) return;
  p.reported = true;
  LOGI("%s cycle=%d win=%dx%d drawable=%dx%d presents=%d resizes=%d "
       "recreates=%d failures=%d", verdict, p.cycle, ww, wh, st.drawable_width,
       st.drawable_height, p.total_presents, st.resizes, st.recreates,
       st.acquire_failures);
}

void OnCmd(android_app* app, int32_t cmd) {
  auto* p = static_cast<Probe*>(app->userData);
  switch (cmd) {
    case APP_CMD_INIT_WINDOW:
      LOGI("probe_window_attach ok=%d",
           p->surface.Init(app->window) ? 1 : 0);
      p->reported = false;
      break;
    case APP_CMD_TERM_WINDOW:
      LOGI("probe_window_detach");
      p->surface.DetachWindow();
      break;
    default:
      break;
  }
}

int32_t OnInput(android_app* app, AInputEvent* event) {
  if (AInputEvent_getType(event) != AINPUT_EVENT_TYPE_KEY) return 0;
  if (AKeyEvent_getKeyCode(event) != AKEYCODE_SPACE) return 0;
  if (AKeyEvent_getAction(event) != AKEY_EVENT_ACTION_UP) return 1;
  auto* p = static_cast<Probe*>(app->userData);
  p->cycle++;
  p->reported = false;
  p->stable_presents = 0;
  const bool landscape = (p->cycle % 2) == 1;
  LOGI("probe_cycle n=%d orientation=%s", p->cycle,
       landscape ? "landscape" : "portrait");
  SetOrientation(app, landscape ? kLandscape : kPortrait);
  return 1;
}

}  // namespace

void android_main(android_app* app) {
  Probe probe;
  app->userData = &probe;
  app->onAppCmd = OnCmd;
  app->onInputEvent = OnInput;
  ANativeActivity_setWindowFlags(
      app->activity,
      AWINDOW_FLAG_KEEP_SCREEN_ON | AWINDOW_FLAG_FULLSCREEN |
          AWINDOW_FLAG_TURN_SCREEN_ON | AWINDOW_FLAG_SHOW_WHEN_LOCKED,
      0);
  LOGI("probe_start");
  while (!app->destroyRequested) {
    int events = 0;
    android_poll_source* source = nullptr;
    // Never block: the frame loop is paced by the FIFO swapchain.
    while (ALooper_pollOnce(probe.surface.valid() ? 0 : 100, nullptr, &events,
                            reinterpret_cast<void**>(&source)) >= 0) {
      if (source != nullptr) source->process(app, source);
      if (app->destroyRequested) break;
    }
    DrawFrame(probe);
  }
  probe.surface.DetachWindow();
}
