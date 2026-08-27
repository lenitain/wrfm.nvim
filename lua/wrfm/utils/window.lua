local term = require("wrfm.utils.term")

local M = {}

---@param winid integer
---@return integer width
---@return integer height
function M.dimensions(winid)
  return vim.api.nvim_win_get_width(winid), vim.api.nvim_win_get_height(winid)
end

---Floating-window config centering a width x height canvas over the editor,
-- or over the anchor window when given; offset_x/offset_y shift the centered
---placement (clamped at 0 so floats never go off-grid).
---@param width integer
---@param height integer
---@param anchor integer?
---@param offset_x integer?
---@param offset_y integer?
---@return vim.api.keyset.win_config
function M.float_config(width, height, anchor, offset_x, offset_y)
  local dx = offset_x or 0
  local dy = offset_y or 0
  if anchor then
    local win_width, win_height = M.dimensions(anchor)
    return {
      relative = "win",
      win = anchor,
      row = math.max(math.floor((win_height - height) / 2) + dy, 0),
      col = math.max(math.floor((win_width - width) / 2) + dx, 0),
      width = width,
      height = height,
    }
  end
  local columns, lines = term.size()
  return {
    relative = "editor",
    row = math.max(math.floor((lines - vim.o.cmdheight - height) / 2) + dy, 0),
    col = math.max(math.floor((columns - width) / 2) + dx, 0),
    width = width,
    height = height,
  }
end

return M
