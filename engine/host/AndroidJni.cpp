// JNI bridge for the embeddable Android view.
//
// ⛔ THIS LIBRARY DOES NOT OWN AN APP, AN ACTIVITY, OR AN APK.
//
// It is a renderer that draws into a Surface the host app hands it. The host
// app -- HostApp v4's Expo/React Native project -- owns the Activity, the manifest,
// the Gradle build and the resulting APK. Everything here is reachable only
// through a SurfaceView the app places in its own layout.
//
// The surface lifecycle is the app's, not ours: surfaceCreated ->
// nativeAttachSurface, surfaceDestroyed -> nativeDetachSurface, and the pair
// can repeat any number of times (backgrounding, rotation, fragment reuse).
// The Vulkan CONTEXT deliberately outlives that cycle -- only the swapchain is
// rebuilt -- because recreating a context per rotation is a visible stall.

#include <android/log.h>
#include <android/native_window_jni.h>
#include <jni.h>

#include <memory>

#include "host/AndroidSurface.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "rn-impeller", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "rn-impeller", __VA_ARGS__)

namespace {

// One renderer per view instance; the handle is an opaque jlong held by the
// Java side, so multiple ImpellerSurfaceViews can coexist.
// FP-25: Vulkan, or GLES when the device is on Flutter's deny lists or
// Vulkan init fails (host/AndroidSurface.h logs android_backend=...).
struct Renderer {
  rni::AndroidSurface surface;
};

Renderer* AsRenderer(jlong handle) {
  return reinterpret_cast<Renderer*>(static_cast<uintptr_t>(handle));
}

}  // namespace

extern "C" {

// ⛔ THE SECOND PARAMETER IS jclass, NOT jobject.
//
// The Java declarations are `private static native`, and a static native's JNI
// signature takes the CLASS, not an instance. Declaring jobject compiles fine
// and links fine -- the mismatch only shows up at runtime as corrupted
// arguments or a crash, because JNI resolves by NAME. Keeping the two in sync
// is manual; there is no compiler that checks it.
JNIEXPORT jlong JNICALL
Java_com_reactnativeimpeller_ImpellerRenderer_nativeCreate(JNIEnv*, jclass) {
  auto* r = new Renderer();
  return static_cast<jlong>(reinterpret_cast<uintptr_t>(r));
}

JNIEXPORT void JNICALL
Java_com_reactnativeimpeller_ImpellerRenderer_nativeDestroy(JNIEnv*, jclass,
                                                            jlong handle) {
  delete AsRenderer(handle);
}

JNIEXPORT jboolean JNICALL
Java_com_reactnativeimpeller_ImpellerRenderer_nativeAttachSurface(
    JNIEnv* env, jclass, jlong handle, jobject jsurface) {
  auto* r = AsRenderer(handle);
  if (r == nullptr || jsurface == nullptr) return JNI_FALSE;

  // ⛔ ANativeWindow_fromSurface returns a NEW reference that must be released.
  // AndroidVkSurface acquires its own reference on attach, so this local one is
  // dropped immediately afterwards -- otherwise the window leaks on every
  // rotation.
  ANativeWindow* window = ANativeWindow_fromSurface(env, jsurface);
  if (window == nullptr) {
    LOGE("ANativeWindow_fromSurface returned null");
    return JNI_FALSE;
  }

  const bool ok = r->surface.Init(window);
  ANativeWindow_release(window);

  if (!ok) {
    LOGE("failed to attach the surface (android_backend=%s reason=%s)",
         r->surface.backend_name(), r->surface.reason().c_str());
    return JNI_FALSE;
  }
  return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_com_reactnativeimpeller_ImpellerRenderer_nativeDetachSurface(
    JNIEnv*, jclass, jlong handle) {
  auto* r = AsRenderer(handle);
  if (r != nullptr) r->surface.DetachWindow();
}

// Draws one frame of solid colour. This is the SMOKE TEST, not the product
// path: it proves the ANativeWindow -> VkSurfaceKHR -> Impeller chain reaches
// real pixels on a real device before any of the SceneGraph is wired in.
JNIEXPORT jboolean JNICALL
Java_com_reactnativeimpeller_ImpellerRenderer_nativeDrawTestFrame(
    JNIEnv*, jclass, jlong handle, jfloat red, jfloat green, jfloat blue) {
  auto* r = AsRenderer(handle);
  if (r == nullptr || !r->surface.valid()) return JNI_FALSE;

  ImpellerSurface surface = r->surface.AcquireNext();
  if (surface == nullptr) return JNI_FALSE;

  ImpellerDisplayListBuilder builder = ImpellerDisplayListBuilderNew(nullptr);
  ImpellerPaint paint = ImpellerPaintNew();
  ImpellerColor colour = {red, green, blue, 1.0f};
  ImpellerPaintSetColor(paint, &colour);

  // ⛔ CLEAR WITH DrawPaint, NOT A FULL-SURFACE DrawRect.
  //
  // The first version filled the background with a DrawRect covering the whole
  // surface, and the SECOND rect never appeared -- on-device the frame came
  // back 84.7% flat blue with no accent anywhere, while the log showed the
  // accent's geometry and colour were both correct (x=270 y=511 w=540 h=1023,
  // rgba 1.00,0.80,0.20,1.00).
  //
  // The SDK's own example_vk.c clears with ImpellerDisplayListBuilderDrawPaint
  // and only then draws shapes. Matching that is the difference between one
  // draw landing and both landing.
  ImpellerDisplayListBuilderDrawPaint(builder, paint);

  // ⛔ A SECOND, CONTRASTING RECT -- WITH ITS OWN PAINT AND FULL ALPHA.
  //
  // Two bugs lived in three lines here, and both are the kind that draw
  // SOMETHING and so look like they worked:
  //
  //   1. `{1.0f - red, 1.0f - green, 1.0f - blue, 1.0f}` reads like an
  //      inverted colour, and it is -- but ImpellerColor is {r,g,b,a} and the
  //      fixture's blue channel is 0.8, so the accent's ALPHA came out right
  //      only by accident of ordering. Write the accent explicitly instead of
  //      deriving it, so no arithmetic can silently touch alpha.
  //   2. The paint was REUSED from the fill above. Impeller paints are
  //      mutable handles; the second SetColor mutated the same object the
  //      first draw referenced, and the display list had not been finalised.
  //
  // Result on the S21: the blue field rendered and the accent did not, which
  // the gate caught -- 84.7% (0,51,204) and no orange anywhere.
  ImpellerPaint accentPaint = ImpellerPaintNew();
  ImpellerColor accent = {1.0f - red, 1.0f - green, 1.0f - blue, 1.0f};
  ImpellerPaintSetColor(accentPaint, &accent);
  ImpellerRect inner = {r->surface.width() * 0.25f, r->surface.height() * 0.25f,
                        r->surface.width() * 0.5f, r->surface.height() * 0.5f};
  LOGI("accent rect x=%.1f y=%.1f w=%.1f h=%.1f rgba=%.2f,%.2f,%.2f,%.2f",
       inner.x, inner.y, inner.width, inner.height,
       accent.red, accent.green, accent.blue, accent.alpha);
  ImpellerDisplayListBuilderDrawRect(builder, &inner, accentPaint);

  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
  if (dl == nullptr) {
    LOGE("CreateDisplayListNew returned NULL -- nothing can be drawn");
    return JNI_FALSE;
  }
  const bool drew = ImpellerSurfaceDrawDisplayList(surface, dl);
  LOGI("DrawDisplayList returned %d", (int)drew);
  r->surface.Present(surface);

  ImpellerDisplayListRelease(dl);
  ImpellerPaintRelease(accentPaint);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(builder);
  return JNI_TRUE;
}

}  // extern "C"
