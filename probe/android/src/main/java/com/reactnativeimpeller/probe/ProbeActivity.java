package com.reactnativeimpeller.probe;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.FrameLayout;

import com.reactnativeimpeller.ImpellerSurfaceView;

/**
 * P10-C device probe. THROWAWAY -- this is not the deliverable.
 *
 * <p>⛔ THE LIBRARY DOES NOT SHIP AN ACTIVITY. Baker's ruling: "We don't want
 * impeller making the apk .. it's just the render." This Activity exists only
 * to be a HOST for the library so the render path can be proven on hardware,
 * exactly as HostApp v4's own app will host it. It lives in a separate probe module
 * and is never part of the AAR.
 *
 * <p>It draws one frame of a known colour pair, then reports success or failure
 * to logcat so a gate can read the result without a human looking at the
 * screen.
 */
public class ProbeActivity extends Activity {

  private ImpellerSurfaceView view;

  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);

    FrameLayout root = new FrameLayout(this);
    view = new ImpellerSurfaceView(this);
    root.addView(view);
    setContentView(root);

    // The surface is not ready synchronously -- surfaceCreated arrives on a
    // later main-loop turn. Poll briefly rather than assume, and FAIL LOUDLY
    // on timeout instead of hanging, so the gate gets a verdict either way.
    final Handler handler = new Handler(Looper.getMainLooper());
    final long deadline = System.currentTimeMillis() + 5000;
    handler.post(new Runnable() {
      @Override
      public void run() {
        if (view.isReady()) {
          // Deep blue fill, orange centre rect (the inverse). Two contrasting
          // colours because a single flat fill cannot distinguish "Impeller
          // drew" from "the swapchain cleared to that colour".
          boolean ok = view.drawTestFrame(0.0f, 0.2f, 0.8f);
          android.util.Log.i("rn-impeller-probe",
              ok ? "PROBE_RESULT=DREW" : "PROBE_RESULT=DRAW_FAILED");
        } else if (System.currentTimeMillis() < deadline) {
          handler.postDelayed(this, 100);
        } else {
          android.util.Log.e("rn-impeller-probe",
              "PROBE_RESULT=SURFACE_NEVER_READY");
        }
      }
    });
  }
}
