package com.reactnativeimpeller;

import android.content.Context;
import android.util.AttributeSet;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

/**
 * A {@link SurfaceView} that renders with Impeller.
 *
 * <p>Drop it into any layout in the host app:
 *
 * <pre>
 *   ImpellerSurfaceView view = new ImpellerSurfaceView(context);
 *   container.addView(view);
 * </pre>
 *
 * <p>⛔ THE HOST APP OWNS THE APK. This view is a renderer that lives inside
 * someone else's Activity; it does not start one, does not declare one, and
 * does not package anything.
 *
 * <p>Surface callbacks arrive on the main thread and are forwarded straight to
 * the native renderer. Rendering itself is driven by the caller (see {@link
 * #drawTestFrame}) rather than an internal loop, so the host app decides when
 * frames happen -- a render thread it owns, a Choreographer callback, or React
 * Native's own frame callbacks.
 */
public class ImpellerSurfaceView extends SurfaceView implements SurfaceHolder.Callback {

  private final ImpellerRenderer renderer = new ImpellerRenderer();
  private boolean surfaceReady;

  public ImpellerSurfaceView(Context context) {
    super(context);
    init();
  }

  public ImpellerSurfaceView(Context context, AttributeSet attrs) {
    super(context, attrs);
    init();
  }

  private void init() {
    getHolder().addCallback(this);
  }

  /** True once the native swapchain exists and frames can be drawn. */
  public boolean isReady() {
    return surfaceReady;
  }

  public boolean drawTestFrame(float red, float green, float blue) {
    return surfaceReady && renderer.drawTestFrame(red, green, blue);
  }

  @Override
  public void surfaceCreated(SurfaceHolder holder) {
    surfaceReady = renderer.attachSurface(holder.getSurface());
  }

  @Override
  public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
    // ⛔ A RESIZE IS A NEW SWAPCHAIN, NOT A RESIZED ONE. A Vulkan swapchain is
    // immutable in extent; presenting to a stale one after rotation returns
    // OUT_OF_DATE forever. Re-attaching rebuilds the swapchain while KEEPING
    // the Vulkan context, which is the expensive half.
    surfaceReady = renderer.attachSurface(holder.getSurface());
  }

  @Override
  public void surfaceDestroyed(SurfaceHolder holder) {
    // Must happen synchronously: after this returns, the Surface is invalid and
    // any native use of it is a use-after-free.
    surfaceReady = false;
    renderer.detachSurface();
  }

  @Override
  protected void onDetachedFromWindow() {
    super.onDetachedFromWindow();
    surfaceReady = false;
    renderer.destroy();
  }
}
