// rni-no-sandbox: stands in for bubblewrap at the BWRAP_EXECUTABLE path compiled into
// Debian's libWPEWebKit-2.0 (2.54, 2022 GLib API: the sandbox is always on and has no
// runtime off-switch). WebKit runs exactly
//     <BWRAP_EXECUTABLE> --args <fd> -- <command> [args...]
// (Source/WebKit/UIProcess/Launcher/glib/BubblewrapLauncher.cpp, bubblewrapSpawn), with
// every sandbox option inside the NUL-separated <fd>. This program closes the fds meant
// for bwrap and execs <command> unsandboxed, which is what a WebKit built with
// ENABLE_BUBBLEWRAP_SANDBOX=OFF (meta-webkit's default, and the M5 cross build) does.
//
// One handshake has to survive: when WebKit thinks the child is sandboxed it does not
// trust the spawned pid (that would be bwrap's) and instead waits on the IPC socket for
// the child's SCM_CREDENTIALS (ProcessLauncherGLib.cpp, Connection::remoteProcessID).
// The real child only sends them when it sees /.flatpak-info, which bwrap creates
// (AuxiliaryProcess::initializeConnection). We exec in place, so our pid IS the child's
// pid: send the same one-byte credentials message (what g_unix_connection_send_credentials
// sends) on the child's socket, argv[2] of every WebKit auxiliary process, then exec.
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static int send_credentials(int fd) {
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISSOCK(st.st_mode)) return -1;
  struct ucred c = {getpid(), getuid(), getgid()};
  char byte = 0;
  struct iovec iov = {&byte, 1};
  union {
    char buf[CMSG_SPACE(sizeof c)];
    struct cmsghdr align;
  } u;
  memset(&u, 0, sizeof u);
  struct msghdr m;
  memset(&m, 0, sizeof m);
  m.msg_iov = &iov;
  m.msg_iovlen = 1;
  m.msg_control = u.buf;
  m.msg_controllen = sizeof u.buf;
  struct cmsghdr* h = CMSG_FIRSTHDR(&m);
  h->cmsg_level = SOL_SOCKET;
  h->cmsg_type = SCM_CREDENTIALS;
  h->cmsg_len = CMSG_LEN(sizeof c);
  memcpy(CMSG_DATA(h), &c, sizeof c);
  ssize_t r;
  do r = sendmsg(fd, &m, MSG_NOSIGNAL); while (r < 0 && errno == EINTR);
  return r == 1 ? 0 : -1;
}

static void close_fd_args(int fd) {
  static char buf[1 << 16];
  size_t n = 0;
  ssize_t r;
  lseek(fd, 0, SEEK_SET);
  while (n < sizeof buf && (r = read(fd, buf + n, sizeof buf - n)) > 0) n += (size_t)r;
  close(fd);
  // Options whose next argument is an fd bwrap would have consumed.
  static const char* fdopts[] = {"--seccomp", "--add-seccomp-fd", "--info-fd", "--json-status-fd",
                                 "--sync-fd", "--block-fd", "--userns-block-fd", "--ro-bind-data",
                                 "--bind-data", "--file", NULL};
  for (size_t i = 0; i < n;) {
    const char* a = buf + i;
    size_t len = strnlen(a, n - i);
    size_t next = i + len + 1;
    for (int k = 0; fdopts[k]; ++k)
      if (strcmp(a, fdopts[k]) == 0 && next < n) close(atoi(buf + next));
    i = next;
  }
}

int main(int argc, char** argv) {
  int i = 1;
  while (i < argc && strcmp(argv[i], "--") != 0) {
    if (strcmp(argv[i], "--args") == 0 && i + 1 < argc) {
      close_fd_args(atoi(argv[i + 1]));
      i += 2;
      continue;
    }
    fprintf(stderr, "rni-no-sandbox: unexpected bwrap argument '%s'\n", argv[i]);
    return 127;
  }
  if (i + 1 >= argc) {
    fprintf(stderr, "rni-no-sandbox: no command after --\n");
    return 127;
  }
  // <command> <process-identifier> <ipc-socket-fd> ... (ProcessLauncherGLib.cpp argv).
  if (i + 3 >= argc || send_credentials(atoi(argv[i + 3])) != 0) {
    fprintf(stderr, "rni-no-sandbox: could not send credentials on fd %s: %s\n",
            i + 3 < argc ? argv[i + 3] : "?", strerror(errno));
    return 127;
  }
  execv(argv[i + 1], argv + i + 1);
  fprintf(stderr, "rni-no-sandbox: exec %s: %s\n", argv[i + 1], strerror(errno));
  return 127;
}
