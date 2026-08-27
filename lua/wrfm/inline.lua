local renderer = require("wrfm.renderer")

---@param value unknown?
---@param fallback unknown
---@return unknown
local function opt(value, fallback)
  if value ~= nil then
    return value
  end
  return fallback
end

local M = {}

---@param Model table Model's metatable
function M.mixin(Model)
  ---Render one frame as virt_lines into the inline buffer via a persistent extmark.
  ---@private
  function Model:_render_inline()
    local bufnr = self.inline_bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    self:_resolve_size()
    local lines = renderer.render_frame(self, {
      rot = self.rot,
      dist = opt(self.dist_opt, self.fit_dist),
      width = self.width,
      height = self.height,
    })
    local virt = {}
    for _, line in ipairs(lines) do
      virt[#virt + 1] = { { line, "WrfmPreview" } }
    end
    local anchor_line = 0
    if self.only_render_at_cursor then
      local wins = vim.fn.win_findbuf(bufnr)
      if #wins > 0 then
        local ok, pos = pcall(vim.api.nvim_win_get_cursor, wins[1])
        if ok and pos then
          anchor_line = math.max(pos[1] - 1, 0)
        end
      end
    end
    local ok, extmark_id =
      pcall(vim.api.nvim_buf_set_extmark, bufnr, self.inline_ns, anchor_line, 0, {
        id = self.inline_extmark_id,
        virt_lines = virt,
        virt_lines_above = self.virt_lines_above ~= false,
        hl_mode = "combine",
      })
    if ok then
      self.inline_extmark_id = extmark_id
    end
  end

  ---Delete the inline extmark (no-op when none exists).
  ---@private
  function Model:_clear_inline()
    if
      self.inline_extmark_id
      and self.inline_bufnr
      and vim.api.nvim_buf_is_valid(self.inline_bufnr)
    then
      pcall(vim.api.nvim_buf_del_extmark, self.inline_bufnr, self.inline_ns, self.inline_extmark_id)
    end
    self.inline_extmark_id = nil
  end

  ---Close the cursor-popup window if open.
  ---@private
  function Model:_close_popup()
    if self.popup_winid and vim.api.nvim_win_is_valid(self.popup_winid) then
      pcall(vim.api.nvim_win_close, self.popup_winid, true)
    end
    self.popup_winid = nil
  end

  ---Show a one-shot floating preview at the cursor; closes on CursorMoved.
  ---While the integration cursor-follow hooks are armed (cursor-only mode),
  ---the popup is instead reopened at each new cursor position by
  ---_follow_cursor, so no self-destruct autocmd is registered here.
  ---@private
  function Model:_render_popup()
    self:_close_popup()
    self:_resolve_size()
    local lines = renderer.render_frame(self, {
      rot = self.rot,
      dist = opt(self.dist_opt, self.fit_dist),
      width = self.width,
      height = self.height,
    })
    local api = vim.api
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    api.nvim_set_option_value("swapfile", false, { buf = buf })
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    for i = 0, #lines - 1 do
      api.nvim_buf_add_highlight(buf, self.inline_ns, "WrfmPreview", i, 0, -1)
    end
    local cols = vim.o.columns
    local popup_w = math.min(self.width or 40, math.floor(cols / 2))
    local popup_h = self.height or #lines
    self.popup_winid = api.nvim_open_win(buf, false, {
      relative = "cursor",
      row = 1,
      col = 0,
      width = popup_w,
      height = popup_h,
      style = "minimal",
      border = "single",
      focusable = false,
      noautocmd = true,
    })
    local follow_active = self.only_render_at_cursor and require("wrfm")._cursor_follow_armed()
    if not follow_active then
      vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        once = true,
        callback = function()
          self:_close_popup()
        end,
      })
    end
  end

  ---Cursor-follow step for cursor-only models: reopen the popup at the moved
  ---cursor, or re-anchor the inline extmark to the new cursor line.
  ---@private
  function Model:_follow_cursor()
    if self.cursor_mode == "popup" then
      self:_render_popup() -- reopens at the current cursor position
    else
      self:_render_inline()
    end
  end

  ---Repaint an open cursor-popup in place (no window/buffer churn per frame).
  ---@private
  function Model:_repaint_popup()
    local api = vim.api
    if not (self.popup_winid and api.nvim_win_is_valid(self.popup_winid)) then
      return
    end
    local lines = renderer.render_frame(self, {
      rot = self.rot,
      dist = opt(self.dist_opt, self.fit_dist),
      width = self.width,
      height = self.height,
    })
    local buf = api.nvim_win_get_buf(self.popup_winid)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(buf, self.inline_ns, 0, -1)
    for i = 0, #lines - 1 do
      api.nvim_buf_add_highlight(buf, self.inline_ns, "WrfmPreview", i, 0, -1)
    end
  end
end

return M
