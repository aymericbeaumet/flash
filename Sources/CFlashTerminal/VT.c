#include "CFlashTerminal.h"
#include <ghostty/vt.h>
#include <stdlib.h>
#include <string.h>
struct FlashVT {
  GhosttyTerminal terminal;
  GhosttyRenderState render;
  GhosttyRenderStateRowIterator rows;
  GhosttyRenderStateRowCells cells;
  GhosttyKeyEncoder keys;
  GhosttyMouseEncoder mouse;
  // One reusable event each; every field an encode reads is set per call.
  GhosttyKeyEvent key_event;
  GhosttyMouseEvent mouse_event;
  // Terminal modes only change through written output or a reset, so the
  // encoders re-read them from the terminal only after one of those.
  bool keys_stale, mouse_stale;
  FlashVTWrite write;
  void *context;
  uint16_t columns, height;
  uint32_t cell_width, cell_height;
  // Row arena for grapheme clusters and hyperlink URIs, addressed by spans.
  uint8_t *arena;
  size_t capacity;
  FlashVTSpan *clusters, *links;
  size_t span_capacity;
  // Frame-scoped state: defaults resolved once, palette loaded on demand.
  GhosttyColorRgb default_fg, default_bg;
  GhosttyColorRgb palette[256];
  bool palette_loaded;
  bool row_positioned;
  uint16_t next_row, row_y;
};
static void write_pty(GhosttyTerminal terminal, void *context,
                      const uint8_t *bytes, size_t length) {
  (void)terminal;
  FlashVT *vt = context;
  if (vt->write)
    vt->write(vt->context, bytes, length);
}
FlashVT *flash_vt_new(uint16_t columns, uint16_t rows, bool scrollback,
                      FlashVTWrite write, void *context) {
  FlashVT *vt = calloc(1, sizeof(*vt));
  if (!vt)
    return NULL;
  if (ghostty_terminal_new(NULL, &vt->terminal, columns, rows) !=
          GHOSTTY_SUCCESS ||
      ghostty_render_state_new(NULL, &vt->render) != GHOSTTY_SUCCESS ||
      ghostty_render_state_row_iterator_new(NULL, &vt->rows) !=
          GHOSTTY_SUCCESS ||
      ghostty_render_state_row_cells_new(NULL, &vt->cells) != GHOSTTY_SUCCESS ||
      ghostty_key_encoder_new(NULL, &vt->keys) != GHOSTTY_SUCCESS ||
      ghostty_mouse_encoder_new(NULL, &vt->mouse) != GHOSTTY_SUCCESS ||
      ghostty_key_event_new(NULL, &vt->key_event) != GHOSTTY_SUCCESS ||
      ghostty_mouse_event_new(NULL, &vt->mouse_event) != GHOSTTY_SUCCESS) {
    flash_vt_free(vt);
    return NULL;
  }
  // Match Ghostty's Unicode width mode so emoji clusters occupy one cell pair.
  GhosttyTerminalModeConfig grapheme = {.mode = GHOSTTY_MODE_GRAPHEME_CLUSTER,
                                        .value = true};
  ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT,
                       &grapheme);
  vt->write = write;
  vt->context = context;
  ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, vt);
  ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, write_pty);
  size_t bytes = scrollback ? 4 * 1024 * 1024 : 0,
         lines = scrollback ? 2000 : 0;
  ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                       &bytes);
  ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
                       &lines);
  vt->cell_width = 1;
  vt->cell_height = 1;
  vt->keys_stale = vt->mouse_stale = true;
  flash_vt_resize(vt, columns, rows);
  return vt;
}
void flash_vt_output(FlashVT *vt, FlashVTWrite write, void *context) {
  vt->write = write;
  vt->context = context;
}
void flash_vt_free(FlashVT *vt) {
  if (!vt)
    return;
  ghostty_mouse_event_free(vt->mouse_event);
  ghostty_key_event_free(vt->key_event);
  ghostty_mouse_encoder_free(vt->mouse);
  ghostty_key_encoder_free(vt->keys);
  ghostty_render_state_row_cells_free(vt->cells);
  ghostty_render_state_row_iterator_free(vt->rows);
  ghostty_render_state_free(vt->render);
  ghostty_terminal_free(vt->terminal);
  free(vt->arena);
  free(vt->clusters);
  free(vt->links);
  free(vt);
}
void flash_vt_write(FlashVT *vt, const uint8_t *bytes, size_t length) {
  ghostty_terminal_vt_write(vt->terminal, bytes, length);
  vt->keys_stale = vt->mouse_stale = true;
}
void flash_vt_reset(FlashVT *vt) {
  ghostty_terminal_reset(vt->terminal);
  vt->keys_stale = vt->mouse_stale = true;
}
void flash_vt_resize(FlashVT *vt, uint16_t columns, uint16_t rows) {
  vt->columns = columns;
  vt->height = rows;
  ghostty_terminal_resize(vt->terminal, columns, rows, vt->cell_width,
                          vt->cell_height);
  GhosttyMouseEncoderSize size = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
  size.screen_width = columns * vt->cell_width;
  size.screen_height = rows * vt->cell_height;
  size.cell_width = vt->cell_width;
  size.cell_height = vt->cell_height;
  ghostty_mouse_encoder_setopt(vt->mouse, GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                               &size);
}
void flash_vt_cell_size(FlashVT *vt, uint32_t width, uint32_t height) {
  vt->cell_width = width ? width : 1;
  vt->cell_height = height ? height : 1;
  flash_vt_resize(vt, vt->columns, vt->height);
}
void flash_vt_colors(FlashVT *vt, FlashRGB foreground, FlashRGB background) {
  GhosttyColorRgb fg = {foreground.r, foreground.g, foreground.b},
                  bg = {background.r, background.g, background.b};
  ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
                       &fg);
  ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
                       &bg);
}
static FlashRGB rgb(GhosttyColorRgb color) {
  return (FlashRGB){color.r, color.g, color.b};
}
bool flash_vt_frame(FlashVT *vt, FlashVTFrame *frame) {
  if (ghostty_render_state_update(vt->render, vt->terminal) != GHOSTTY_SUCCESS)
    return false;
  memset(frame, 0, sizeof(*frame));
  frame->columns = vt->columns;
  frame->rows = vt->height;
  GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
  ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
  frame->dirty = dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE     ? 0
                 : dirty == GHOSTTY_RENDER_STATE_DIRTY_PARTIAL ? 1
                                                               : 2;
  GhosttyRenderStateCursor cursor =
      GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
  ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_CURSOR,
                           &cursor);
  frame->cursor_visible = cursor.visible && cursor.viewport_has_value;
  frame->cursor_blinking = cursor.blinking;
  if (cursor.viewport_has_value) {
    frame->cursor_x = cursor.viewport_x;
    frame->cursor_y = cursor.viewport_y;
  }
  frame->cursor_style = cursor.visual_style;
  vt->default_fg = (GhosttyColorRgb){255, 255, 255};
  vt->default_bg = (GhosttyColorRgb){0, 0, 0};
  ghostty_render_state_get(vt->render,
                           GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND,
                           &vt->default_fg);
  ghostty_render_state_get(vt->render,
                           GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND,
                           &vt->default_bg);
  frame->foreground = rgb(vt->default_fg);
  frame->background = rgb(vt->default_bg);
  ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
                       &frame->mouse_tracking);
  ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                           &vt->rows);
  vt->palette_loaded = false;
  vt->row_positioned = false;
  vt->next_row = 0;
  return true;
}
bool flash_vt_next_row(FlashVT *vt, bool all, uint16_t *y) {
  uint16_t next = vt->next_row;
  bool moved = all ? ghostty_render_state_row_iterator_next(vt->rows)
                   : ghostty_render_state_row_iterator_next_dirty(vt->rows,
                                                                  &next);
  vt->row_positioned = moved;
  if (!moved)
    return false;
  vt->row_y = next;
  vt->next_row = next + 1;
  *y = next;
  return true;
}
static bool arena_reserve(FlashVT *vt, size_t needed) {
  if (needed <= vt->capacity)
    return true;
  size_t capacity = vt->capacity ? vt->capacity : 4096;
  while (capacity < needed)
    capacity *= 2;
  uint8_t *grown = realloc(vt->arena, capacity);
  if (!grown)
    return false;
  vt->arena = grown;
  vt->capacity = capacity;
  return true;
}
static bool spans_reserve(FlashVT *vt, size_t needed) {
  if (needed <= vt->span_capacity)
    return true;
  size_t capacity = needed < 64 ? 64 : needed;
  FlashVTSpan *clusters = realloc(vt->clusters, capacity * sizeof(FlashVTSpan));
  if (clusters)
    vt->clusters = clusters;
  FlashVTSpan *links = realloc(vt->links, capacity * sizeof(FlashVTSpan));
  if (links)
    vt->links = links;
  if (!clusters || !links)
    return false;
  vt->span_capacity = capacity;
  return true;
}
static GhosttyColorRgb resolve(FlashVT *vt, GhosttyStyleColor color,
                               GhosttyColorRgb fallback) {
  if (color.tag == GHOSTTY_STYLE_COLOR_RGB)
    return color.value.rgb;
  if (color.tag != GHOSTTY_STYLE_COLOR_PALETTE)
    return fallback;
  if (!vt->palette_loaded) {
    ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE,
                             &vt->palette);
    vt->palette_loaded = true;
  }
  return vt->palette[color.value.palette];
}
// Appends the current cell's grapheme cluster to the arena; returns its
// cluster index or -1.
static int append_cluster(FlashVT *vt, size_t *used, uint16_t count) {
  for (;;) {
    GhosttyBuffer text = {.ptr = vt->capacity > *used ? vt->arena + *used
                                                      : NULL,
                          .cap = vt->capacity - *used};
    GhosttyResult result = ghostty_render_state_row_cells_get(
        vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &text);
    if (result == GHOSTTY_SUCCESS) {
      if (!text.len)
        return -1;
      vt->clusters[count] = (FlashVTSpan){(uint32_t)*used, (uint32_t)text.len};
      *used += text.len;
      return count;
    }
    if (result != GHOSTTY_OUT_OF_SPACE || !arena_reserve(vt, *used + text.len))
      return -1;
  }
}
// Appends the hyperlink URI at column `x`, sharing the previous entry when a
// link run continues. Returns the 1-based link index or 0.
static uint16_t append_link(FlashVT *vt, size_t *used, uint16_t *count,
                            uint16_t x) {
  GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT,
                        .value.coordinate = {.x = x, .y = vt->row_y}};
  GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  if (ghostty_terminal_grid_ref(vt->terminal, point, &ref) != GHOSTTY_SUCCESS)
    return 0;
  for (;;) {
    size_t length = 0;
    GhosttyResult result = ghostty_grid_ref_hyperlink_uri(
        &ref, vt->capacity > *used ? vt->arena + *used : NULL,
        vt->capacity - *used, &length);
    if (result == GHOSTTY_SUCCESS) {
      if (!length || length > 8192)
        return 0;
      if (*count) {
        FlashVTSpan last = vt->links[*count - 1];
        if (last.length == length &&
            !memcmp(vt->arena + last.offset, vt->arena + *used, length))
          return *count;
      }
      vt->links[*count] = (FlashVTSpan){(uint32_t)*used, (uint32_t)length};
      *used += length;
      return ++*count;
    }
    if (result != GHOSTTY_OUT_OF_SPACE || length > 8192 ||
        !arena_reserve(vt, *used + length))
      return 0;
  }
}
static bool select_cell(FlashVT *vt, bool *ready, uint16_t x) {
  if (!*ready) {
    if (ghostty_render_state_row_get(vt->rows,
                                     GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                     &vt->cells) != GHOSTTY_SUCCESS)
      return false;
    *ready = true;
  }
  return ghostty_render_state_row_cells_select(vt->cells, x) ==
         GHOSTTY_SUCCESS;
}
bool flash_vt_row_cells(FlashVT *vt, FlashVTCell *cells, FlashVTRow *row) {
  if (!vt->row_positioned || !spans_reserve(vt, vt->columns))
    return false;
  memset(row, 0, sizeof(*row));
  // Row-level summaries let plain rows skip the per-cell style, grapheme and
  // hyperlink lookups; they may report false positives, never negatives.
  bool styled = true, linked = true, grapheme = true;
  GhosttyRow raw_row = 0;
  if (ghostty_render_state_row_get(vt->rows, GHOSTTY_RENDER_STATE_ROW_DATA_RAW,
                                   &raw_row) == GHOSTTY_SUCCESS) {
    GhosttyRowData keys[] = {GHOSTTY_ROW_DATA_WRAP, GHOSTTY_ROW_DATA_STYLED,
                             GHOSTTY_ROW_DATA_HYPERLINK,
                             GHOSTTY_ROW_DATA_GRAPHEME};
    void *values[] = {&row->wrapped, &styled, &linked, &grapheme};
    ghostty_row_get_multi(raw_row, 4, keys, values, NULL);
  }
  GhosttyCellsView raw = {0};
  if (ghostty_render_state_row_get(vt->rows,
                                   GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW,
                                   &raw) != GHOSTTY_SUCCESS ||
      raw.len < vt->columns)
    return false;
  static const GhosttyCellData keys[] = {
      GHOSTTY_CELL_DATA_CODEPOINT, GHOSTTY_CELL_DATA_CONTENT_TAG,
      GHOSTTY_CELL_DATA_WIDE, GHOSTTY_CELL_DATA_HAS_STYLING,
      GHOSTTY_CELL_DATA_HAS_HYPERLINK};
  size_t key_count = linked ? 5 : styled ? 4 : 3;
  size_t used = 0;
  uint16_t clusters = 0, links = 0, row_flags = 0;
  // The per-cell handle is positioned on this row only once a cell needs a
  // grapheme or style lookup.
  bool cells_ready = false;
  for (uint16_t x = 0; x < vt->columns; x++) {
    uint32_t codepoint = 0;
    GhosttyCellContentTag tag = GHOSTTY_CELL_CONTENT_CODEPOINT;
    GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
    bool has_styling = false, has_link = false;
    void *values[] = {&codepoint, &tag, &wide, &has_styling, &has_link};
    ghostty_cell_get_multi(raw.ptr[x], key_count, keys, values, NULL);
    GhosttyColorRgb fg = vt->default_fg, bg = vt->default_bg;
    uint32_t content = codepoint;
    if (tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME &&
        select_cell(vt, &cells_ready, x)) {
      int index = append_cluster(vt, &used, clusters);
      if (index >= 0) {
        content = FLASH_VT_CLUSTER | (uint32_t)index;
        clusters++;
      }
    } else if (tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
      GhosttyColorPaletteIndex index = 0;
      ghostty_cell_get(raw.ptr[x], GHOSTTY_CELL_DATA_COLOR_PALETTE, &index);
      bg = resolve(vt,
                   (GhosttyStyleColor){.tag = GHOSTTY_STYLE_COLOR_PALETTE,
                                       .value.palette = index},
                   bg);
      content = 0;
    } else if (tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
      ghostty_cell_get(raw.ptr[x], GHOSTTY_CELL_DATA_COLOR_RGB, &bg);
      content = 0;
    }
    uint16_t flags = 0;
    uint8_t underline = 0;
    GhosttyColorRgb underline_color;
    if (has_styling && select_cell(vt, &cells_ready, x)) {
      GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
      ghostty_render_state_row_cells_get(
          vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
      flags = style.bold | style.italic << 1 | style.faint << 2 |
              style.blink << 3 | style.inverse << 4 | style.invisible << 5 |
              style.strikethrough << 6 | style.overline << 7;
      underline = (uint8_t)style.underline;
      fg = resolve(vt, style.fg_color, fg);
      // A background-only cell's own color wins over its style, as in
      // libghostty's resolved background.
      if (tag == GHOSTTY_CELL_CONTENT_CODEPOINT ||
          tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME)
        bg = resolve(vt, style.bg_color, bg);
      underline_color = resolve(vt, style.underline_color, fg);
    } else {
      underline_color = fg;
    }
    uint16_t link = has_link ? append_link(vt, &used, &links, x) : 0;
    row_flags |= flags;
    cells[x] = (FlashVTCell){
        .content = content,
        .flags = flags,
        .link = link,
        .foreground = rgb(fg),
        .background = rgb(bg),
        .underline_color = rgb(underline_color),
        .width = wide == GHOSTTY_CELL_WIDE_WIDE     ? 2
                 : wide == GHOSTTY_CELL_WIDE_NARROW ? 1
                                                    : 0,
        .underline = underline,
    };
  }
  row->flags = row_flags;
  row->cluster_count = clusters;
  row->link_count = links;
  row->arena = vt->arena;
  row->clusters = vt->clusters;
  row->links = vt->links;
  return true;
}
void flash_vt_clean(FlashVT *vt) { ghostty_render_state_clean(vt->render); }
void flash_vt_scroll(FlashVT *vt, int lines) {
  GhosttyTerminalScrollViewport scroll = {.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
                                          .value.delta = lines};
  ghostty_terminal_scroll_viewport(vt->terminal, scroll);
}
static GhosttyKey mac_key(uint16_t key) {
  switch (key) {
  case 54:
    return GHOSTTY_KEY_META_RIGHT;
  case 55:
    return GHOSTTY_KEY_META_LEFT;
  case 56:
    return GHOSTTY_KEY_SHIFT_LEFT;
  case 57:
    return GHOSTTY_KEY_CAPS_LOCK;
  case 58:
    return GHOSTTY_KEY_ALT_LEFT;
  case 59:
    return GHOSTTY_KEY_CONTROL_LEFT;
  case 60:
    return GHOSTTY_KEY_SHIFT_RIGHT;
  case 61:
    return GHOSTTY_KEY_ALT_RIGHT;
  case 62:
    return GHOSTTY_KEY_CONTROL_RIGHT;

  case 0:
    return GHOSTTY_KEY_A;
  case 1:
    return GHOSTTY_KEY_S;
  case 2:
    return GHOSTTY_KEY_D;
  case 3:
    return GHOSTTY_KEY_F;
  case 4:
    return GHOSTTY_KEY_H;
  case 5:
    return GHOSTTY_KEY_G;
  case 6:
    return GHOSTTY_KEY_Z;
  case 7:
    return GHOSTTY_KEY_X;
  case 8:
    return GHOSTTY_KEY_C;
  case 9:
    return GHOSTTY_KEY_V;
  case 11:
    return GHOSTTY_KEY_B;
  case 12:
    return GHOSTTY_KEY_Q;
  case 13:
    return GHOSTTY_KEY_W;
  case 14:
    return GHOSTTY_KEY_E;
  case 15:
    return GHOSTTY_KEY_R;
  case 16:
    return GHOSTTY_KEY_Y;
  case 17:
    return GHOSTTY_KEY_T;
  case 18:
    return GHOSTTY_KEY_DIGIT_1;
  case 19:
    return GHOSTTY_KEY_DIGIT_2;
  case 20:
    return GHOSTTY_KEY_DIGIT_3;
  case 21:
    return GHOSTTY_KEY_DIGIT_4;
  case 22:
    return GHOSTTY_KEY_DIGIT_6;
  case 23:
    return GHOSTTY_KEY_DIGIT_5;
  case 24:
    return GHOSTTY_KEY_EQUAL;
  case 25:
    return GHOSTTY_KEY_DIGIT_9;
  case 26:
    return GHOSTTY_KEY_DIGIT_7;
  case 27:
    return GHOSTTY_KEY_MINUS;
  case 28:
    return GHOSTTY_KEY_DIGIT_8;
  case 29:
    return GHOSTTY_KEY_DIGIT_0;
  case 30:
    return GHOSTTY_KEY_BRACKET_RIGHT;
  case 31:
    return GHOSTTY_KEY_O;
  case 32:
    return GHOSTTY_KEY_U;
  case 33:
    return GHOSTTY_KEY_BRACKET_LEFT;
  case 34:
    return GHOSTTY_KEY_I;
  case 35:
    return GHOSTTY_KEY_P;
  case 36:
    return GHOSTTY_KEY_ENTER;
  case 37:
    return GHOSTTY_KEY_L;
  case 38:
    return GHOSTTY_KEY_J;
  case 39:
    return GHOSTTY_KEY_QUOTE;
  case 40:
    return GHOSTTY_KEY_K;
  case 41:
    return GHOSTTY_KEY_SEMICOLON;
  case 42:
    return GHOSTTY_KEY_BACKSLASH;
  case 43:
    return GHOSTTY_KEY_COMMA;
  case 44:
    return GHOSTTY_KEY_SLASH;
  case 45:
    return GHOSTTY_KEY_N;
  case 46:
    return GHOSTTY_KEY_M;
  case 47:
    return GHOSTTY_KEY_PERIOD;
  case 48:
    return GHOSTTY_KEY_TAB;
  case 49:
    return GHOSTTY_KEY_SPACE;
  case 50:
    return GHOSTTY_KEY_BACKQUOTE;
  case 51:
    return GHOSTTY_KEY_BACKSPACE;
  case 53:
    return GHOSTTY_KEY_ESCAPE;
  case 65:
    return GHOSTTY_KEY_NUMPAD_DECIMAL;
  case 67:
    return GHOSTTY_KEY_NUMPAD_MULTIPLY;
  case 69:
    return GHOSTTY_KEY_NUMPAD_ADD;
  case 71:
    return GHOSTTY_KEY_NUM_LOCK;
  case 75:
    return GHOSTTY_KEY_NUMPAD_DIVIDE;
  case 76:
    return GHOSTTY_KEY_NUMPAD_ENTER;
  case 78:
    return GHOSTTY_KEY_NUMPAD_SUBTRACT;
  case 81:
    return GHOSTTY_KEY_NUMPAD_EQUAL;
  case 82:
    return GHOSTTY_KEY_NUMPAD_0;
  case 83:
    return GHOSTTY_KEY_NUMPAD_1;
  case 84:
    return GHOSTTY_KEY_NUMPAD_2;
  case 85:
    return GHOSTTY_KEY_NUMPAD_3;
  case 86:
    return GHOSTTY_KEY_NUMPAD_4;
  case 87:
    return GHOSTTY_KEY_NUMPAD_5;
  case 88:
    return GHOSTTY_KEY_NUMPAD_6;
  case 89:
    return GHOSTTY_KEY_NUMPAD_7;
  case 91:
    return GHOSTTY_KEY_NUMPAD_8;
  case 92:
    return GHOSTTY_KEY_NUMPAD_9;
  case 96:
    return GHOSTTY_KEY_F5;
  case 97:
    return GHOSTTY_KEY_F6;
  case 98:
    return GHOSTTY_KEY_F7;
  case 99:
    return GHOSTTY_KEY_F3;
  case 100:
    return GHOSTTY_KEY_F8;
  case 101:
    return GHOSTTY_KEY_F9;
  case 103:
    return GHOSTTY_KEY_F11;
  case 105:
    return GHOSTTY_KEY_F13;
  case 107:
    return GHOSTTY_KEY_F14;
  case 109:
    return GHOSTTY_KEY_F10;
  case 111:
    return GHOSTTY_KEY_F12;
  case 113:
    return GHOSTTY_KEY_F15;
  case 114:
    return GHOSTTY_KEY_HELP;
  case 115:
    return GHOSTTY_KEY_HOME;
  case 116:
    return GHOSTTY_KEY_PAGE_UP;
  case 117:
    return GHOSTTY_KEY_DELETE;
  case 118:
    return GHOSTTY_KEY_F4;
  case 119:
    return GHOSTTY_KEY_END;
  case 120:
    return GHOSTTY_KEY_F2;
  case 121:
    return GHOSTTY_KEY_PAGE_DOWN;
  case 122:
    return GHOSTTY_KEY_F1;
  case 123:
    return GHOSTTY_KEY_ARROW_LEFT;
  case 124:
    return GHOSTTY_KEY_ARROW_RIGHT;
  case 125:
    return GHOSTTY_KEY_ARROW_DOWN;
  case 126:
    return GHOSTTY_KEY_ARROW_UP;
  default:
    return GHOSTTY_KEY_UNIDENTIFIED;
  }
}
void flash_vt_key(FlashVT *vt, uint16_t key, uint16_t mods, int action,
                  const char *text, size_t length, uint32_t unshifted) {
  if (vt->keys_stale) {
    ghostty_key_encoder_setopt_from_terminal(vt->keys, vt->terminal);
    vt->keys_stale = false;
  }
  GhosttyKeyEvent event = vt->key_event;
  ghostty_key_event_set_action(event, (GhosttyKeyAction)action);
  ghostty_key_event_set_key(event, mac_key(key));
  ghostty_key_event_set_mods(event, mods);
  ghostty_key_event_set_consumed_mods(event,
                                      text && length ? mods & GHOSTTY_MODS_SHIFT
                                                     : 0);
  ghostty_key_event_set_utf8(event, text, length);
  ghostty_key_event_set_unshifted_codepoint(event, unshifted);
  char output[4096];
  size_t count = 0;
  if (ghostty_key_encoder_encode(vt->keys, event, output, sizeof(output),
                                 &count) == GHOSTTY_SUCCESS &&
      count)
    write_pty(vt->terminal, vt, (uint8_t *)output, count);
}
void flash_vt_mouse(FlashVT *vt, int action, int button, uint16_t mods,
                    double x, double y) {
  if (vt->mouse_stale) {
    ghostty_mouse_encoder_setopt_from_terminal(vt->mouse, vt->terminal);
    vt->mouse_stale = false;
  }
  GhosttyMouseEvent event = vt->mouse_event;
  ghostty_mouse_event_set_action(event, (GhosttyMouseAction)action);
  if (button > 0)
    ghostty_mouse_event_set_button(event, (GhosttyMouseButton)button);
  else
    ghostty_mouse_event_clear_button(event);
  ghostty_mouse_event_set_mods(event, mods);
  ghostty_mouse_event_set_position(
      event, (GhosttyMousePosition){x * vt->cell_width, y * vt->cell_height});
  bool pressed = button > 0 && action != GHOSTTY_MOUSE_ACTION_RELEASE;
  ghostty_mouse_encoder_setopt(
      vt->mouse, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
  char output[256];
  size_t count = 0;
  if (ghostty_mouse_encoder_encode(vt->mouse, event, output, sizeof(output),
                                   &count) == GHOSTTY_SUCCESS &&
      count)
    write_pty(vt->terminal, vt, (uint8_t *)output, count);
}
static bool mode(FlashVT *vt, GhosttyMode mode) {
  GhosttyTerminalModeConfig query = {.mode = mode};
  return ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_MODE,
                              &query) == GHOSTTY_SUCCESS &&
         query.value;
}
void flash_vt_paste(FlashVT *vt, char *text, size_t length) {
  size_t capacity = length + 12, count = 0;
  char *output = malloc(capacity);
  if (!output)
    return;
  if (ghostty_paste_encode(text, length, mode(vt, GHOSTTY_MODE_BRACKETED_PASTE),
                           output, capacity, &count) == GHOSTTY_SUCCESS)
    write_pty(vt->terminal, vt, (uint8_t *)output, count);
  free(output);
}
void flash_vt_focus(FlashVT *vt, bool focused) {
  if (mode(vt, GHOSTTY_MODE_FOCUS_EVENT))
    write_pty(vt->terminal, vt,
              (const uint8_t *)(focused ? "\033[I" : "\033[O"), 3);
}

size_t flash_unicode_width(const uint32_t *codepoints, size_t count) {
  size_t offset = 0, total = 0;
  while (offset < count) {
    uint8_t width = 0;
    size_t consumed = ghostty_unicode_grapheme_width(codepoints + offset,
                                                     count - offset, &width);
    if (consumed == 0)
      break;
    offset += consumed;
    total += width;
  }
  return total;
}
