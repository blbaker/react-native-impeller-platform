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

#include "host/AndroidVkSurface.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "rn-impeller", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "rn-impeller", __VA_ARGS__)

namespace {

// One renderer per view instance; the handle is an opaque jlong held by the
// Java side, so multiple ImpellerSurfaceViews can coexist.
struct Renderer {
  rni::AndroidVkSurface surface;
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
    LOGE("failed to attach Vulkan surface");
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

  ImpellerRect rect = {0, 0, (float)r->surface.width(),
                       (float)r->surface.height()};
  ImpellerDisplayListBuilderDrawRect(builder, &rect, paint);

  // A second, contrasting rect: a single flat colour cannot distinguish "we
  // drew" from "the swapchain cleared to that colour".
  ImpellerColor accent = {1.0f - red, 1.0f - green, 1.0f - blue, 1.0f};
  ImpellerPaintSetColor(paint, &accent);
  ImpellerRect inner = {r->surface.width() * 0.25f, r->surface.height() * 0.25f,
                        r->surface.width() * 0.5f, r->surface.height() * 0.5f};
  ImpellerDisplayListBuilderDrawRect(builder, &inner, paint);

  ImpellerDisplayList dl = ImpellerDisplayListBuilderCreateDisplayListNew(builder);
  ImpellerSurfaceDrawDisplayList(surface, dl);
  r->surface.Present(surface);

  ImpellerDisplayListRelease(dl);
  ImpellerPaintRelease(paint);
  ImpellerDisplayListBuilderRelease(builder);
  return JNI_TRUE;
}

}  // extern "C"
