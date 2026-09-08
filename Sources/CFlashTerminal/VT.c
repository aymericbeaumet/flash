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
  FlashVTWrite write;
  void *context;
  uint16_t columns, height, current_row;
  uint32_t cell_width, cell_height;
  uint8_t *text;
  size_t capacity;
  uint8_t *hyperlink;
  size_t hyperlink_capacity;
  bool row_wrapped;
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
      ghostty_mouse_encoder_new(NULL, &vt->mouse) != GHOSTTY_SUCCESS) {
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
  ghostty_mouse_encoder_free(vt->mouse);
  ghostty_key_encoder_free(vt->keys);
  ghostty_render_state_row_cells_free(vt->cells);
  ghostty_render_state_row_iterator_free(vt->rows);
  ghostty_render_state_free(vt->render);
  ghostty_terminal_free(vt->terminal);
  free(vt->text);
  free(vt->hyperlink);
  free(vt);
}
void flash_vt_write(FlashVT *vt, const uint8_t *bytes, size_t length) {
  ghostty_terminal_vt_write(vt->terminal, bytes, length);
}
void flash_vt_reset(FlashVT *vt) { ghostty_terminal_reset(vt->terminal); }
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
  GhosttyColorRgb fg = {255, 255, 255}, bg = {0, 0, 0};
  ghostty_render_state_get(vt->render,
                           GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &fg);
  ghostty_render_state_get(vt->render,
                           GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &bg);
  frame->foreground = rgb(fg);
  frame->background = rgb(bg);
  ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
                       &frame->mouse_tracking);
  ghostty_render_state_get(vt->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                           &vt->rows);
  vt->current_row = UINT16_MAX;
  return true;
}
bool flash_vt_cell(FlashVT *vt, uint16_t x, uint16_t y, FlashVTCell *cell) {
  while (vt->current_row == UINT16_MAX || vt->current_row < y) {
    if (!ghostty_render_state_row_iterator_next(vt->rows))
      return false;
    vt->current_row = vt->current_row == UINT16_MAX ? 0 : vt->current_row + 1;
    ghostty_render_state_row_get(vt->rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                 &vt->cells);
    GhosttyRow row = 0;
    vt->row_wrapped = false;
    if (ghostty_render_state_row_get(vt->rows, GHOSTTY_RENDER_STATE_ROW_DATA_RAW,
                                     &row) != GHOSTTY_SUCCESS)
      return false;
    ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &vt->row_wrapped);
  }
  if (ghostty_render_state_row_cells_select(vt->cells, x) != GHOSTTY_SUCCESS)
    return false;
  memset(cell, 0, sizeof(*cell));
  cell->row_wrapped = vt->row_wrapped;
  GhosttyBuffer text = {.ptr = vt->text, .cap = vt->capacity};
  if (ghostty_render_state_row_cells_get(
          vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
          &text) == GHOSTTY_OUT_OF_SPACE) {
    uint8_t *grown = realloc(vt->text, text.len);
    if (!grown)
      return false;
    vt->text = grown;
    vt->capacity = text.len;
    text.ptr = grown;
    text.cap = vt->capacity;
    ghostty_render_state_row_cells_get(
        vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &text);
  }
  cell->text = text.ptr;
  cell->length = text.len;
  GhosttyColorRgb fg = {255, 255, 255}, bg = {0, 0, 0};
  ghostty_render_state_get(vt->render,
                           GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &fg);
  ghostty_render_state_get(vt->render,
                           GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &bg);
  ghostty_render_state_row_cells_get(
      vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
  ghostty_render_state_row_cells_get(
      vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);
  cell->foreground = rgb(fg);
  cell->background = rgb(bg);
  cell->underline_color = rgb(fg);
  GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
  ghostty_render_state_row_cells_get(
      vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
  cell->flags = style.bold | style.italic << 1 | style.faint << 2 |
                style.blink << 3 | style.inverse << 4 | style.invisible << 5 |
                style.strikethrough << 6 | style.overline << 7;
  cell->underline = style.underline;
  if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB)
    cell->underline_color = rgb(style.underline_color.value.rgb);
  else if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
    GhosttyColorRgb palette[256];
    ghostty_render_state_get(vt->render,
                             GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE, &palette);
    cell->underline_color = rgb(palette[style.underline_color.value.palette]);
  }
  GhosttyCell raw;
  GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
  ghostty_render_state_row_cells_get(
      vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
  bool has_hyperlink = false;
  ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &has_hyperlink);
  if (has_hyperlink) {
    GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT,
                          .value.coordinate = {.x = x, .y = y}};
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    if (ghostty_terminal_grid_ref(vt->terminal, point, &ref) == GHOSTTY_SUCCESS) {
      size_t length = 0;
      GhosttyResult result = ghostty_grid_ref_hyperlink_uri(
          &ref, vt->hyperlink, vt->hyperlink_capacity, &length);
      if (result == GHOSTTY_OUT_OF_SPACE && length <= 8192) {
        uint8_t *grown = realloc(vt->hyperlink, length);
        if (!grown)
          return false;
        vt->hyperlink = grown;
        vt->hyperlink_capacity = length;
        result = ghostty_grid_ref_hyperlink_uri(
            &ref, vt->hyperlink, vt->hyperlink_capacity, &length);
      }
      if (result == GHOSTTY_SUCCESS && length <= 8192) {
        cell->hyperlink = vt->hyperlink;
        cell->hyperlink_length = length;
      }
    }
  }
  ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
  cell->width = wide == GHOSTTY_CELL_WIDE_WIDE     ? 2
                : wide == GHOSTTY_CELL_WIDE_NARROW ? 1
                                                   : 0;
  return true;
}
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
  GhosttyKeyEvent event;
  if (ghostty_key_event_new(NULL, &event) != GHOSTTY_SUCCESS)
    return;
  ghostty_key_encoder_setopt_from_terminal(vt->keys, vt->terminal);
  ghostty_key_event_set_action(event, (GhosttyKeyAction)action);
  ghostty_key_event_set_key(event, mac_key(key));
  ghostty_key_event_set_mods(event, mods);
  ghostty_key_event_set_utf8(event, text, length);
  ghostty_key_event_set_unshifted_codepoint(event, unshifted);
  if (text && length)
    ghostty_key_event_set_consumed_mods(event, mods & GHOSTTY_MODS_SHIFT);
  char output[4096];
  size_t count = 0;
  if (ghostty_key_encoder_encode(vt->keys, event, output, sizeof(output),
                                 &count) == GHOSTTY_SUCCESS &&
      count)
    write_pty(vt->terminal, vt, (uint8_t *)output, count);
  ghostty_key_event_free(event);
}
void flash_vt_mouse(FlashVT *vt, int action, int button, uint16_t mods,
                    double x, double y) {
  GhosttyMouseEvent event;
  if (ghostty_mouse_event_new(NULL, &event) != GHOSTTY_SUCCESS)
    return;
  ghostty_mouse_encoder_setopt_from_terminal(vt->mouse, vt->terminal);
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
  ghostty_mouse_event_free(event);
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
