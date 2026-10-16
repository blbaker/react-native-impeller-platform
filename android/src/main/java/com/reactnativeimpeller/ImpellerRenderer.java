package com.reactnativeimpeller;

import android.view.Surface;

/**
 * Thin JNI wrapper around the native Impeller renderer.
 *
 * <p>⛔ THIS CLASS OWNS NO WINDOW AND NO ACTIVITY. It draws into a {@link
 * Surface} that the host application supplies. The app that embeds this library
 * owns its own Activity, manifest, Gradle build and APK -- this is a renderer,
 * not an app framework.
 *
 * <p>Lifecycle contract, which the caller must honour:
 * <pre>
 *   create()                 once per view
 *   attachSurface(surface)   on every surfaceCreated / surfaceChanged
 *   detachSurface()          on every surfaceDestroyed
 *   destroy()                once, when the view is gone for good
 * </pre>
 *
 * <p>attach/detach may repeat any number of times (backgrounding, rotation,
 * fragment reuse). The native Vulkan CONTEXT survives that cycle deliberately;
 * only the swapchain is rebuilt, because recreating a context per rotation is
 * a visible stall.
 */
public final class ImpellerRenderer {

  static {
    // ⛔ ORDER MATTERS. libreactnativeimpeller.so has a NEEDED entry on
    // libimpeller.so; on older Android loaders an implicit dependency is not
    // always resolved from the APK's lib dir, so load the dependency first.
    System.loadLibrary("impeller");
    System.loadLibrary("reactnativeimpeller");
  }

  private long handle;

  public ImpellerRenderer() {
    handle = nativeCreate();
  }

  /** True when a surface is attached and frames can be drawn. */
  public boolean isValid() {
    return handle != 0L;
  }

  public boolean attachSurface(Surface surface) {
    if (handle == 0L || surface == null) {
      return false;
    }
    return nativeAttachSurface(handle, surface);
  }

  public void detachSurface() {
    if (handle != 0L) {
      nativeDetachSurface(handle);
    }
  }

  /**
   * Draws one solid frame. This is the SMOKE TEST path, not the product path:
   * it proves the Surface -> VkSurfaceKHR -> Impeller chain reaches real pixels
   * on a real device before any scene graph is involved.
   */
  public boolean drawTestFrame(float red, float green, float blue) {
    if (handle == 0L) {
      return false;
    }
    return nativeDrawTestFrame(handle, red, green, blue);
  }

  /** Releases native resources. The instance is unusable afterwards. */
  public void destroy() {
    if (handle != 0L) {
      nativeDestroy(handle);
      handle = 0L;
    }
  }

  /** Forwards ComponentCallbacks2.onTrimMemory; a memory-pressure level purges the image cache. */
  public static void onTrimMemory(int level) {
    nativeOnTrimMemory(level);
  }

  private static native void nativeOnTrimMemory(int level);

  private static native long nativeCreate();

  private static native void nativeDestroy(long handle);

  private static native boolean nativeAttachSurface(long handle, Surface surface);

  private static native void nativeDetachSurface(long handle);

  private static native boolean nativeDrawTestFrame(
      long handle, float red, float green, float blue);
}
