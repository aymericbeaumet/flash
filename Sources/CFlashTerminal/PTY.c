#include "CFlashTerminal.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

int flash_spawn_file_actions_addchdir(posix_spawn_file_actions_t *actions,
                                      const char *path) {
  // The replacement spelling is absent from SDKs predating macOS 26.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return posix_spawn_file_actions_addchdir_np(actions, path);
#pragma clang diagnostic pop
}

int flash_pty_spawn(const char *executable, char *const argv[],
                    char *const env[], const char *directory, uint16_t columns,
                    uint16_t rows, pid_t *pid) {
  int errors[2];
  if (pipe(errors) < 0)
    return -1;
  fcntl(errors[0], F_SETFD, FD_CLOEXEC);
  fcntl(errors[1], F_SETFD, FD_CLOEXEC);
  int descriptor_limit = getdtablesize();
  struct winsize size = {.ws_col = columns, .ws_row = rows};
  int master;
  pid_t child = forkpty(&master, NULL, NULL, &size);
  if (child == 0) {
    close(errors[0]);
    for (int fd = 3; fd < descriptor_limit; fd++) {
      if (fd != errors[1])
        close(fd);
    }
    // Only async-signal-safe C calls execute between fork and exec.
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    for (int sig = 1; sig < NSIG; sig++)
      sigaction(sig, &action, NULL);
    sigset_t signals;
    sigemptyset(&signals);
    sigprocmask(SIG_SETMASK, &signals, NULL);
    if (!directory || chdir(directory) == 0)
      execve(executable, argv, env);
    int error = errno;
    write(errors[1], &error, sizeof(error));
    _exit(127);
  }
  close(errors[1]);
  if (child < 0) {
    int error = errno;
    close(errors[0]);
    errno = error;
    return -1;
  }
  int error = 0;
  ssize_t count;
  do {
    count = read(errors[0], &error, sizeof(error));
  } while (count < 0 && errno == EINTR);
  close(errors[0]);
  if (count > 0) {
    close(master);
    waitpid(child, NULL, 0);
    errno = error;
    return -1;
  }
  fcntl(master, F_SETFD, FD_CLOEXEC);
  fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
  *pid = child;
  return master;
}
int flash_pty_resize(int fd, uint16_t columns, uint16_t rows) {
  struct winsize size = {.ws_col = columns, .ws_row = rows};
  return ioctl(fd, TIOCSWINSZ, &size);
}
void flash_pty_signal(int fd, pid_t pid, int signal, bool include_leader) {
  if (pid <= 0)
    return;
  pid_t foreground = tcgetpgrp(fd);
  if (foreground > 0 && foreground != pid)
    kill(-foreground, signal);
  kill(-pid, signal);
  if (include_leader)
    kill(pid, signal);
}
int flash_pty_wait(pid_t pid, int *status) {
  int raw;
  pid_t result = waitpid(pid, &raw, WNOHANG);
  if (result > 0)
    *status = WIFEXITED(raw) ? WEXITSTATUS(raw) : 128 + WTERMSIG(raw);
  return (int)result;
}

int flash_pty_resize_pixels(int fd, uint16_t columns, uint16_t rows,
                            uint32_t cell_width, uint32_t cell_height) {
  struct winsize size = {
      .ws_col = columns,
      .ws_row = rows,
      .ws_xpixel =
          (unsigned short)(columns * cell_width > 65535 ? 65535
                                                        : columns * cell_width),
      .ws_ypixel =
          (unsigned short)(rows * cell_height > 65535 ? 65535
                                                      : rows * cell_height)};
  return ioctl(fd, TIOCSWINSZ, &size);
}
