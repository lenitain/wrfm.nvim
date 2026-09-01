-- Visual-column math for overlay compositing.
--
-- `z_order = "text"` skips model cells that the buffer already paints with
-- text: a cell belongs to the text when the real line content shows a glyph
-- at that visual (buffer) column. This module answers "which visual columns
-- does this line's text occupy?" strictly from the buffer-side line content,
-- so it is deterministic in headless tests and does not depend on a window
-- being attached or a screen being present.
--
-- Two display effects push a byte offset away from its visual column:
--   * tab expansion (tabstop)
--   * wide (double-width) characters (CJK, emoji, ...)
-- The window-side decorations a split adds (signcolumn, number column,
-- `listchars`, `conceal`) do not reflow the buffer itself, so they do not
-- move the artwork columns. `listchars` is the one acknowledged gap: trailing
-- whitespace that `listchars` renders as visible glyphs is not counted as
-- occupying a column, which only ever makes `text` yield more cells to the
-- model than a strictly faithful compositor would -- it never hides model art
-- that should show.
--
-- Overlay extmarks are placed by *byte* offset (`nvim_buf_set_extmark` takes
-- a byte column), while the artwork grid is visual, so `scan` returns both
-- and `inline._build_overlay` places extmarks at `byte_at[col]` instead of
-- the visual column.
local M = {}

---Scan a buffer line once and return what the overlay needs:
---  * `occupied`  visual columns owning a visible glyph (spaces and the
---    columns a tab spans are blank and free for the model to paint, which is
---    what lets `z_order = "text"` lay art over padding and between words);
---  * `byte_at`   visual column -> byte offset, only for columns an extmark
---    can be placed at: the first column of a glyph, of a space, and of a
---    tab. A wide glyph's second column and a tab's interior columns have no
---    entry because an extmark can only start at a glyph boundary.
--- Iterating by codepoint makes a multibyte character contribute its true
--- display width (2 for wide glyphs, 0 for combining marks, which merge into
--- the glyph before them and so add no column and no placement change).
---@param text string buffer line content
---@param tabstop? integer tab expansion width (default 8)
---@return table<integer, boolean> occupied
---@return table<integer, integer> byte_at
function M.scan(text, tabstop)
  tabstop = tabstop or 8
  local occupied, byte_at = {}, {}
  local count = vim.fn.strchars(text)
  local col, byte = 0, 0
  for i = 0, count - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    local width
    if ch == "\t" then
      width = tabstop - (col % tabstop)
    elseif ch == " " then
      width = 1
    else
      width = vim.fn.strwidth(ch)
    end
    if width > 0 then
      byte_at[col] = byte
      if ch ~= "\t" and ch ~= " " then
        for c = col, col + width - 1 do
          occupied[c] = true
        end
      end
      col = col + width
    end
    byte = byte + #ch
  end
  return occupied, byte_at
end

---The set of visual columns occupied by visible glyphs in `text`.
---@param text string buffer line content
---@param tabstop? integer tab expansion width (default 8)
---@return table<integer, boolean>
function M.occupied_columns(text, tabstop)
  local occupied = M.scan(text, tabstop)
  return occupied
end

---Whether the line shows displayable content at visual column `col`.
---@param text string buffer line content
---@param col integer visual column (0-based)
---@param tabstop? integer tab expansion width (default 8)
---@return boolean
function M.occupied(text, col, tabstop)
  return M.occupied_columns(text, tabstop)[col] == true
end

return M
