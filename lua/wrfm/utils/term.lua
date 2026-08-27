local M = {}

---Editor grid size: (columns, lines).
---@return integer columns
---@return integer lines
function M.size()
  return vim.o.columns, vim.o.lines
end

return M
