local M = {}

---Rows of the editor grid that actually show buffer text: the screen minus the
---command line, and minus the statusline row when it is global (image.nvim's
---convention for the visible frame of an in-buffer object).
---@return integer
function M.text_lines()
  local statusline = (vim.o.laststatus == 2 or vim.o.laststatus == 3) and 1 or 0
  return math.max(vim.o.lines - vim.o.cmdheight - statusline, 1)
end

---Editor grid size: (columns, lines).
---@return integer columns
---@return integer lines
function M.size()
  return vim.o.columns, vim.o.lines
end

return M
