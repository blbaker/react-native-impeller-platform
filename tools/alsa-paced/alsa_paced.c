/* A paced ALSA playback device for tools/ci-video-audio.sh: built as a stand-in
 * libasound.so.2 (soname and the nine snd_* entry points the engine's
 * video/AudioSinkAlsa.cpp dlsym's), put first on LD_LIBRARY_PATH. WSL has no
 * sound card and no snd-aloop, and alsa-lib's own null/file plugins never
 * block and keep no clock, so they cannot show WHEN a sample is heard.
 *
 * This device plays like an ALSA hw PCM opened with snd_pcm_set_params:
 * - a ring of the requested latency, drained at exactly the stream rate on a
 *   monotonic clock;
 * - start threshold = the whole buffer (what snd_pcm_set_params sets): after
 *   open, drop or an underrun nothing plays until the ring is full;
 * - the ring running dry is an underrun: the next write fails -EPIPE until
 *   snd_pcm_recover;
 * - snd_pcm_delay = frames in the ring; snd_pcm_drop empties it at once;
 * - SND_PCM_NONBLOCK: a full ring is -EAGAIN, snd_pcm_wait waits for room.
 * Every frame the device plays (a zero frame when it is not running: silence)
 * is appended to $RNI_PACED_OUT, so frame k of the capture was HEARD at wall
 * t0 + k / rate, with t0 (epoch ms, the clock of JS Date.now()) in
 * $RNI_PACED_OUT.t0.
 *
 *   RNI_PACED_LOSE_SEC=N   from N s after open, writes fail -ENODEV (unplugged;
 *                          snd_pcm_recover cannot fix it)
 *   RNI_PACED_HANG_SEC=N   at N s after open the device stops consuming. A
 *   RNI_PACED_HANG_FOR=M   BLOCKING write then returns -EIO M s later (the
 *                          kernel's "write error (DMA or IRQ trouble?)"
 *                          timeout); a non-blocking one gets -EAGAIN
 *
 *   cc -shared -fPIC -O2 -Wl,-soname,libasound.so.2 -o libasound.so.2 alsa_paced.c -lpthread
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct snd_pcm {
  pthread_mutex_t mu;
  pthread_cond_t cv;
  pthread_t th;
  int run, channels, running, xrun, nonblock;
  unsigned rate;
  int16_t* ring;
  long cap, head, fill; /* frames */
  FILE* out;
  double opened, lose_after, hang_at, hang_for;
} snd_pcm_t;

static double mono(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

static double env_sec(const char* name) {
  const char* v = getenv(name);
  return v && *v ? atof(v) : -1;
}

static int hung(const snd_pcm_t* p) { return p->hang_at >= 0 && mono() - p->opened >= p->hang_at; }

static void* playout(void* arg) {
  snd_pcm_t* p = arg;
  struct timespec real, next;
  clock_gettime(CLOCK_REALTIME, &real);
  clock_gettime(CLOCK_MONOTONIC, &next);
  const double t0 = next.tv_sec + next.tv_nsec / 1e9;
  char path[4096];
  snprintf(path, sizeof path, "%s.t0", getenv("RNI_PACED_OUT"));
  FILE* f = fopen(path, "w");
  if (f) {
    fprintf(f, "%.3f\n", real.tv_sec * 1e3 + real.tv_nsec / 1e6);
    fclose(f);
  }
  long played = 0;
  int16_t* buf = calloc((size_t)p->rate * p->channels, sizeof(int16_t));
  pthread_mutex_lock(&p->mu);
  while (p->run) {
    pthread_mutex_unlock(&p->mu);
    next.tv_nsec += 5 * 1000 * 1000; /* 5 ms ticks */
    if (next.tv_nsec >= 1000000000) next.tv_nsec -= 1000000000, next.tv_sec++;
    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
    pthread_mutex_lock(&p->mu);
    long due = (long)((mono() - t0) * p->rate) - played;
    if (due <= 0) continue;
    if (due > (long)p->rate) due = p->rate;
    if (!p->running && !p->xrun && p->fill >= p->cap) p->running = 1; /* start threshold */
    const int consume = p->running && !hung(p);
    for (long i = 0; i < due; ++i) {
      int16_t* d = buf + i * p->channels;
      if (consume && p->fill > 0) {
        memcpy(d, p->ring + p->head * p->channels, sizeof(int16_t) * p->channels);
        p->head = (p->head + 1) % p->cap;
        p->fill--;
      } else {
        memset(d, 0, sizeof(int16_t) * p->channels);
      }
    }
    if (consume && p->fill == 0) p->running = 0, p->xrun = 1; /* underrun */
    fwrite(buf, sizeof(int16_t) * p->channels, (size_t)due, p->out);
    played += due;
    pthread_cond_broadcast(&p->cv);
  }
  pthread_mutex_unlock(&p->mu);
  free(buf);
  return NULL;
}

int snd_pcm_open(snd_pcm_t** pcm, const char* name, int stream, int mode) {
  (void)name;
  if (stream != 0) return -EINVAL; /* playback only */
  const char* out = getenv("RNI_PACED_OUT");
  if (!out || !*out) return -ENOENT;
  snd_pcm_t* p = calloc(1, sizeof *p);
  p->out = fopen(out, "wb");
  if (!p->out) {
    free(p);
    return -errno;
  }
  pthread_mutex_init(&p->mu, NULL);
  pthread_cond_init(&p->cv, NULL);
  p->lose_after = env_sec("RNI_PACED_LOSE_SEC");
  p->hang_at = env_sec("RNI_PACED_HANG_SEC");
  p->hang_for = env_sec("RNI_PACED_HANG_FOR");
  p->nonblock = mode & 1; /* SND_PCM_NONBLOCK */
  p->opened = mono();
  *pcm = p;
  return 0;
}

int snd_pcm_set_params(snd_pcm_t* p, int format, int access, unsigned channels, unsigned rate, int resample,
                       unsigned latency_us) {
  (void)resample;
  if (format != 2 /* S16_LE */ || access != 3 /* RW_INTERLEAVED */ || channels < 1 || rate < 8000) return -EINVAL;
  p->channels = (int)channels;
  p->rate = rate;
  p->cap = (long)((double)latency_us * rate / 1e6);
  if (p->cap < 256) p->cap = 256;
  p->ring = calloc((size_t)p->cap * channels, sizeof(int16_t));
  p->run = 1;
  return pthread_create(&p->th, NULL, playout, p) == 0 ? 0 : -EIO;
}

long snd_pcm_writei(snd_pcm_t* p, const void* data, unsigned long frames) {
  const int16_t* src = data;
  unsigned long done = 0;
  pthread_mutex_lock(&p->mu);
  while (done < frames) {
    if (p->lose_after >= 0 && mono() - p->opened >= p->lose_after) break;
    if (p->xrun) break;
    if (p->fill == p->cap) {
      if (p->nonblock) break; /* -EAGAIN, or the partial count */
      if (hung(p) && mono() - p->opened >= p->hang_at + (p->hang_for > 0 ? p->hang_for : 1e9)) {
        pthread_mutex_unlock(&p->mu);
        return done > 0 ? (long)done : -EIO;
      }
      pthread_cond_wait(&p->cv, &p->mu);
      continue;
    }
    const long tail = (p->head + p->fill) % p->cap;
    memcpy(p->ring + tail * p->channels, src + done * p->channels, sizeof(int16_t) * p->channels);
    p->fill++;
    done++;
  }
  const int lost = p->lose_after >= 0 && mono() - p->opened >= p->lose_after, xrun = p->xrun;
  pthread_mutex_unlock(&p->mu);
  if (done > 0) return (long)done;
  return lost ? -ENODEV : xrun ? -EPIPE : -EAGAIN;
}

/* 1 = room to write, 0 = timed out, -EPIPE = underrun. */
int snd_pcm_wait(snd_pcm_t* p, int timeout_ms) {
  const double until = mono() + timeout_ms / 1e3;
  int r;
  pthread_mutex_lock(&p->mu);
  while (!p->xrun && p->fill == p->cap && mono() < until) pthread_cond_wait(&p->cv, &p->mu);
  r = p->xrun ? -EPIPE : p->fill < p->cap ? 1 : 0;
  pthread_mutex_unlock(&p->mu);
  return r;
}

int snd_pcm_recover(snd_pcm_t* p, int err, int silent) {
  (void)silent;
  if (err != -EPIPE && err != -ESTRPIPE && err != -EINTR) return err;
  pthread_mutex_lock(&p->mu);
  p->xrun = 0; /* re-prepared: plays again once the ring is full */
  pthread_mutex_unlock(&p->mu);
  return 0;
}

int snd_pcm_delay(snd_pcm_t* p, long* delay) {
  pthread_mutex_lock(&p->mu);
  *delay = p->fill;
  pthread_mutex_unlock(&p->mu);
  return 0;
}

int snd_pcm_drop(snd_pcm_t* p) {
  pthread_mutex_lock(&p->mu);
  p->head = p->fill = 0;
  p->running = 0;
  pthread_cond_broadcast(&p->cv);
  pthread_mutex_unlock(&p->mu);
  return 0;
}

int snd_pcm_prepare(snd_pcm_t* p) {
  pthread_mutex_lock(&p->mu);
  p->xrun = 0;
  pthread_mutex_unlock(&p->mu);
  return 0;
}

int snd_pcm_close(snd_pcm_t* p) {
  pthread_mutex_lock(&p->mu);
  int was = p->run;
  p->run = 0;
  pthread_cond_broadcast(&p->cv);
  pthread_mutex_unlock(&p->mu);
  if (was) pthread_join(p->th, NULL);
  fclose(p->out);
  free(p->ring);
  free(p);
  return 0;
}

const char* snd_strerror(int err) { return strerror(err < 0 ? -err : err); }
