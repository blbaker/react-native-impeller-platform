/* rni-touch-inject: a Weston module that injects REAL touch events through
 * libweston's own input path (notify_touch_normalized -> weston_touch ->
 * wl_touch on the focused client), driven by lines written to a FIFO.
 *
 * Why it exists: the headless backend has no input devices, and Debian ships
 * no weston-test plugin. Without a compositor-side source of wl_touch, the
 * engine's Wayland touch listener (host/WaylandTouch.cpp) could only be
 * exercised by calling its own callbacks, which proves nothing about the
 * protocol path. This puts a touch device on a seat exactly like libinput
 * does on a board, so the client sees a genuine wl_seat touch capability and
 * genuine wl_touch.down/motion/up events.
 *
 * Load: weston --modules=/path/rni-touch-inject.so   (env RNI_TOUCH_FIFO=path)
 * FIFO lines (global compositor coordinates; the kiosk output is at 0,0):
 *   down X Y      move X Y      up      cancel
 *
 * Built against Weston 10 (Debian bookworm, the arm64 test container),
 * Weston 13 (Ubuntu 24.04, the x64 test container) and Weston 16 (Debian
 * sid, the web view test container). The seat/touch-device
 * entry points are WL_EXPORTed by libweston but declared in its private
 * headers, so their prototypes are restated here verbatim from
 * libweston/libweston-internal.h and libweston/backend.h of each version.
 * Weston 12-15 pass a weston_coord_global; Weston 16 passes one
 * weston_touch_event (public struct) and adds a set_output callback to
 * weston_touch_create_touch_device. A wrong prototype here is an ABI break
 * that compiles cleanly, so each branch quotes the version it came from.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <libweston/libweston.h>
#include <libweston/version.h>
#include <wayland-server.h>

/* libweston/libweston-internal.h (same in 10.0.1 and 16.0.0) */
void weston_seat_init(struct weston_seat *seat, struct weston_compositor *ec, const char *seat_name);
int weston_seat_init_touch(struct weston_seat *seat);
#if WESTON_VERSION_MAJOR >= 16
/* weston 16.0.0 libweston/libweston-internal.h + libweston/backend.h */
struct weston_touch_device *weston_touch_create_touch_device(
    struct weston_touch *touch, const char *syspath, void *backend_data,
    const struct weston_touch_device_ops *ops, weston_touch_device_set_output_func_t set_output);
void notify_touch_normalized(const struct weston_touch_event *event,
                             const struct weston_point2d_device_normalized *norm);
#define CREATE_TOUCH_DEVICE(t, name) weston_touch_create_touch_device((t), (name), NULL, NULL, NULL)
static void touch_at(struct weston_touch_device *d, const struct timespec *t, int id, double x,
                     double y, int type) {
  struct weston_touch_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.base.ts = *t;
  ev.base.seat = d->aggregate->seat;
  ev.device = d;
  ev.touch_type = type;
  ev.touch_id = id;
  ev.pos.c = weston_coord(x, y);
  notify_touch_normalized(&ev, NULL);
}
#else
/* weston 10.0.1 libweston/libweston-internal.h */
struct weston_touch_device *weston_touch_create_touch_device(struct weston_touch *touch,
                                                             const char *syspath,
                                                             void *backend_data,
                                                             const struct weston_touch_device_ops *ops);
#define CREATE_TOUCH_DEVICE(t, name) weston_touch_create_touch_device((t), (name), NULL, NULL)
#endif
#if WESTON_VERSION_MAJOR >= 16
/* touch_at above */
#elif WESTON_VERSION_MAJOR >= 12
/* weston 13.0.0 / 14.0 libweston/backend.h */
void notify_touch_normalized(struct weston_touch_device *device, const struct timespec *time,
                             int touch_id, const struct weston_coord_global *pos,
                             const struct weston_point2d_device_normalized *norm, int touch_type);
static void touch_at(struct weston_touch_device *d, const struct timespec *t, int id, double x,
                     double y, int type) {
  /* 13.0.0 input.c asserts pos != NULL for down/motion and pos == NULL for up. */
  struct weston_coord_global pos = {.c = weston_coord(x, y)};
  notify_touch_normalized(d, t, id, type == WL_TOUCH_UP ? NULL : &pos, NULL, type);
}
#else
/* weston 10.0.1 libweston/backend.h */
void notify_touch_normalized(struct weston_touch_device *device, const struct timespec *time,
                             int touch_id, double x, double y,
                             const struct weston_point2d_device_normalized *norm, int touch_type);
static void touch_at(struct weston_touch_device *d, const struct timespec *t, int id, double x,
                     double y, int type) {
  notify_touch_normalized(d, t, id, x, y, NULL, type);
}
#endif
void notify_touch_frame(struct weston_touch_device *device);
void notify_touch_cancel(struct weston_touch_device *device);

struct inject {
  struct weston_compositor *ec;
  struct weston_seat seat;
  struct weston_touch_device *dev;
  int fd;
  char buf[512];
  size_t len;
  int down;
};

static void handle_line(struct inject *in, char *line) {
  struct timespec now;
  double x = 0, y = 0;
  weston_compositor_get_time(&now);
  if (sscanf(line, "down %lf %lf", &x, &y) == 2) {
    touch_at(in->dev, &now, 0, x, y, WL_TOUCH_DOWN);
    notify_touch_frame(in->dev);
    in->down = 1;
  } else if (sscanf(line, "move %lf %lf", &x, &y) == 2) {
    touch_at(in->dev, &now, 0, x, y, WL_TOUCH_MOTION);
    notify_touch_frame(in->dev);
  } else if (strncmp(line, "up", 2) == 0) {
    touch_at(in->dev, &now, 0, 0, 0, WL_TOUCH_UP);
    notify_touch_frame(in->dev);
    in->down = 0;
  } else if (strncmp(line, "cancel", 6) == 0) {
    notify_touch_cancel(in->dev);
    in->down = 0;
  } else {
    weston_log("rni-touch-inject: ignored line '%s'\n", line);
    return;
  }
  weston_log("rni-touch-inject: %s\n", line);
}

static int on_fifo(int fd, uint32_t mask, void *data) {
  struct inject *in = data;
  (void)mask;
  for (;;) {
    ssize_t r = read(fd, in->buf + in->len, sizeof(in->buf) - 1 - in->len);
    if (r <= 0) break;
    in->len += (size_t)r;
    in->buf[in->len] = '\0';
    char *nl;
    while ((nl = strchr(in->buf, '\n')) != NULL) {
      *nl = '\0';
      handle_line(in, in->buf);
      size_t rest = in->len - (size_t)(nl + 1 - in->buf);
      memmove(in->buf, nl + 1, rest);
      in->len = rest;
      in->buf[in->len] = '\0';
    }
    if (in->len >= sizeof(in->buf) - 1) in->len = 0; /* overlong line: drop */
  }
  return 0;
}

WL_EXPORT int wet_module_init(struct weston_compositor *ec, int *argc, char *argv[]) {
  (void)argc; (void)argv;
  const char *path = getenv("RNI_TOUCH_FIFO");
  if (path == NULL) path = "/tmp/rni-touch.fifo";
  struct inject *in = calloc(1, sizeof(*in));
  if (in == NULL) return -1;
  in->ec = ec;
  weston_seat_init(&in->seat, ec, "rni-touch");
  if (weston_seat_init_touch(&in->seat) < 0) { weston_log("rni-touch-inject: no touch\n"); return -1; }
  in->dev = CREATE_TOUCH_DEVICE(in->seat.touch_state, "rni-touch-inject");
  if (in->dev == NULL) { weston_log("rni-touch-inject: no device\n"); return -1; }
  unlink(path);
  if (mkfifo(path, 0666) != 0) { weston_log("rni-touch-inject: mkfifo %s: %s\n", path, strerror(errno)); return -1; }
  /* O_RDWR: the FIFO never reports EOF when a writer closes, so one open
   * serves every writer for the compositor's lifetime. */
  in->fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
  if (in->fd < 0) { weston_log("rni-touch-inject: open %s: %s\n", path, strerror(errno)); return -1; }
  wl_event_loop_add_fd(wl_display_get_event_loop(ec->wl_display), in->fd, WL_EVENT_READABLE, on_fifo, in);
  weston_log("rni-touch-inject: seat 'rni-touch' with a touch device, fifo %s\n", path);
  return 0;
}
