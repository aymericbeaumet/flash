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
/// `FlashVTCell.content` bit marking a multi-codepoint grapheme cluster; the
/// low bits index the row's cluster spans.
#define FLASH_VT_CLUSTER 0x80000000u
/// One viewport cell, stored unchanged as Swift row storage: 20 bytes with no
/// padding, so rows compare with `memcmp`. `content` is 0 for an empty cell,
/// a Unicode scalar, or `FLASH_VT_CLUSTER | index`. `link` is 0 or a 1-based
/// index into the row's link spans; consecutive cells share one entry.
typedef struct {
  uint32_t content;
  uint16_t flags;
  uint16_t link;
  FlashRGB foreground, background, underline_color;
  uint8_t width, underline, reserved;
} FlashVTCell;
/// UTF-8 bytes in the row arena.
typedef struct {
  uint32_t offset, length;
} FlashVTSpan;
typedef struct {
  uint16_t columns, rows, cursor_x, cursor_y;
  bool cursor_visible, cursor_blinking, mouse_tracking;
  uint8_t cursor_style;
  /// 0: no row changed since the last `flash_vt_clean`; 1: only the rows
  /// `flash_vt_next_row` visits changed; 2: every row changed.
  uint8_t dirty;
  FlashRGB foreground, background;
} FlashVTFrame;
/// Row metadata and text tables filled by `flash_vt_row_cells`. The arena and
/// span arrays stay valid until the next `flash_vt_row_cells` call.
typedef struct {
  bool wrapped;
  /// Union of every cell's flags.
  uint16_t flags;
  uint16_t cluster_count, link_count;
  const uint8_t *arena;
  const FlashVTSpan *clusters, *links;
} FlashVTRow;
FlashVT *flash_vt_new(uint16_t columns, uint16_t rows, uint32_t scrollback_lines,
                      FlashVTWrite write, void *context);
void flash_vt_output(FlashVT *vt, FlashVTWrite write, void *context);
void flash_vt_free(FlashVT *vt);
void flash_vt_write(FlashVT *vt, const uint8_t *bytes, size_t length);
void flash_vt_reset(FlashVT *vt);
void flash_vt_resize(FlashVT *vt, uint16_t columns, uint16_t rows);
void flash_vt_cell_size(FlashVT *vt, uint32_t width, uint32_t height);
void flash_vt_colors(FlashVT *vt, FlashRGB foreground, FlashRGB background);
/// Refresh the render state and describe the viewport. Rows are then read in
/// ascending order with `flash_vt_next_row`; finish with `flash_vt_clean`.
bool flash_vt_frame(FlashVT *vt, FlashVTFrame *frame);
/// Advance to the next row to rebuild and report its viewport index: every
/// row when `all`, otherwise only rows libghostty reports dirty. Returns false
/// past the last such row.
bool flash_vt_next_row(FlashVT *vt, bool all, uint16_t *y);
/// Fill `columns` cells of the current row and describe its text tables.
bool flash_vt_row_cells(FlashVT *vt, FlashVTCell *cells, FlashVTRow *row);
/// Mark every dirty flag consumed after a complete frame was read.
void flash_vt_clean(FlashVT *vt);
void flash_vt_scroll(FlashVT *vt, int lines);
void flash_vt_key(FlashVT *vt, uint16_t mac_key, uint16_t mods, int action,
                  const char *text, size_t length, uint32_t unshifted);
void flash_vt_mouse(FlashVT *vt, int action, int button, uint16_t mods,
                    double x, double y);
void flash_vt_paste(FlashVT *vt, char *text, size_t length);
void flash_vt_focus(FlashVT *vt, bool focused);
/// The step of `flash_pty_spawn` that failed, reported with `errno`: creating
/// the PTY and child, entering the working directory, or `execve`.
#define FLASH_PTY_STEP_SPAWN 0
#define FLASH_PTY_STEP_DIRECTORY 1
#define FLASH_PTY_STEP_EXEC 2
/// Forks a child on a new PTY and executes `executable` in `directory`.
/// Returns the master descriptor, or -1 with `errno` and `failed_step` set.
int flash_pty_spawn(const char *executable, char *const argv[],
                    char *const env[], const char *directory, uint16_t columns,
                    uint16_t rows, pid_t *pid, int *failed_step);
int flash_pty_resize(int fd, uint16_t columns, uint16_t rows);
int flash_pty_resize_pixels(int fd, uint16_t columns, uint16_t rows,
                            uint32_t cell_width, uint32_t cell_height);
void flash_pty_signal(int fd, pid_t pid, int signal, bool include_leader);
int flash_pty_wait(pid_t pid, int *status);
/// Reap child `pid`, blocking until it is reapable, and store its status as
/// a shell reports it (exit code, or 128 + signal). Call it only once the
/// child's exit was reported: the kernel posts the exit event a moment before
/// the child becomes reapable, and this waits out those last exit steps.
/// Returns the pid, or -1 (errno ECHILD) when there is nothing to reap.
int flash_pty_reap(pid_t pid, int *status);
/// Wait up to `timeout_ms` for `pid` to exit without polling. Returns 1 once
/// the kernel reports the exit, 0 on timeout, -1 when no exit event can be
/// registered (the process already exited, or kqueue failed).
int flash_pty_await_exit(pid_t pid, int timeout_ms);
int flash_spawn_file_actions_addchdir(posix_spawn_file_actions_t *actions,
                                      const char *path);

size_t flash_unicode_width(const uint32_t *codepoints, size_t count);
