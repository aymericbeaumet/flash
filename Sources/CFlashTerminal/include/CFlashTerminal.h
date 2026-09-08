#pragma once
#include <spawn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
typedef struct FlashVT FlashVT;
typedef void (*FlashVTWrite)(void *, const uint8_t *, size_t);
typedef struct {
  uint8_t r, g, b;
} FlashRGB;
typedef struct {
  const uint8_t *text;
  size_t length;
  FlashRGB foreground, background, underline_color;
  uint16_t flags;
  uint8_t width, underline;
} FlashVTCell;
typedef struct {
  uint16_t columns, rows, cursor_x, cursor_y;
  bool cursor_visible, cursor_blinking, mouse_tracking;
  uint8_t cursor_style;
  FlashRGB foreground, background;
} FlashVTFrame;
FlashVT *flash_vt_new(uint16_t columns, uint16_t rows, bool scrollback,
                      FlashVTWrite write, void *context);
void flash_vt_output(FlashVT *vt, FlashVTWrite write, void *context);
void flash_vt_free(FlashVT *vt);
void flash_vt_write(FlashVT *vt, const uint8_t *bytes, size_t length);
void flash_vt_reset(FlashVT *vt);
void flash_vt_resize(FlashVT *vt, uint16_t columns, uint16_t rows);
void flash_vt_cell_size(FlashVT *vt, uint32_t width, uint32_t height);
void flash_vt_colors(FlashVT *vt, FlashRGB foreground, FlashRGB background);
bool flash_vt_frame(FlashVT *vt, FlashVTFrame *frame);
bool flash_vt_cell(FlashVT *vt, uint16_t x, uint16_t y, FlashVTCell *cell);
void flash_vt_scroll(FlashVT *vt, int lines);
void flash_vt_key(FlashVT *vt, uint16_t mac_key, uint16_t mods, int action,
                  const char *text, size_t length, uint32_t unshifted);
void flash_vt_mouse(FlashVT *vt, int action, int button, uint16_t mods,
                    double x, double y);
void flash_vt_paste(FlashVT *vt, char *text, size_t length);
void flash_vt_focus(FlashVT *vt, bool focused);
int flash_pty_spawn(const char *executable, char *const argv[],
                    char *const env[], const char *directory, uint16_t columns,
                    uint16_t rows, pid_t *pid);
int flash_pty_resize(int fd, uint16_t columns, uint16_t rows);
int flash_pty_resize_pixels(int fd, uint16_t columns, uint16_t rows,
                            uint32_t cell_width, uint32_t cell_height);
void flash_pty_signal(int fd, pid_t pid, int signal, bool include_leader);
int flash_pty_wait(pid_t pid, int *status);
int flash_spawn_file_actions_addchdir(posix_spawn_file_actions_t *actions,
                                      const char *path);

size_t flash_unicode_width(const uint32_t *codepoints, size_t count);
