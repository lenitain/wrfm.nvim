local renderer = require("wrfm.renderer")
local virtcol = require("wrfm.utils.virtcol")

local M = {}

-- Compositing budget: a healthy wireframe renders a handful of extmarks, but a
-- large model bleeding into a big text block can fan out into hundreds of
-- segments. Above this count the overlay is not worth its per-segment extmark
-- cost, so the frame degrades to a clipped canvas render (far fewer extmarks)
-- and tells the user once.
local MAX_OVERLAY_EXMARKS = 512

---@param Model table Model's metatable
function M.mixin(Model)
  ---The channel a live view paints through. Inline previews composite on top
  ---of the host buffer's real text lines via virt_text overlay; the cursor-only
  ---popup is its own floating window. There is no virt_lines push channel.
  ---@private
  ---@return "overlay"|"popup"
  function Model:_render_channel()
    if self:_uses_popup() then
      return "popup"
    end
    return "overlay"
  end

  ---Tell the user once when a `z_order`/`overflow` request had to degrade.
  ---@private
  ---@param msg string
  function Model:_overlay_warn(msg)
    if not self._overlay_warned then
      self._overlay_warned = true
      vim.notify_once(msg, vim.log.levels.WARN)
    end
  end

  ---The (line, col) in the inline buffer that the canvas' top-left cell
  ---(absolute (0, 0)) maps to. The canvas never moves horizontally (column 0),
  ---and its top row follows the same anchor the old virt_lines path used: line
  ---0 for a normal preview, the cursor line for `only_render_at_cursor`.
  ---@private
  ---@return integer line
  ---@return integer col
  function Model:_overlay_origin()
    local line = 0
    if self.only_render_at_cursor and self.inline_bufnr then
      local wins = vim.fn.win_findbuf(self.inline_bufnr)
      if #wins > 0 then
        local ok, pos = pcall(vim.api.nvim_win_get_cursor, wins[1])
        if ok and pos then
          line = math.max(pos[1] - 1, 0)
        end
      end
    end
    return line, 0
  end

  ---Bleed cells needed to expose the whole painted footprint, or nil when the
  ---frame must stay clipped to the canvas. `overflow = "clip"` (the default)
  ---draws nothing outside the canvas; `visible` sizes the bleed to exactly the
  ---footprint so no dot the canvas would crop is lost (decision ⑥: no cap, only
  ---natural boundaries).
  ---@private
  ---@param view WrfmView
  ---@return WrfmBleed?
  function Model:_bleed(view)
    if self.overflow ~= "visible" then
      return nil
    end
    local any, min_col, max_col, min_row, max_row = renderer.footprint(self, view)
    if not any then
      return nil
    end
    return {
      left = math.max(0, -min_col),
      right = math.max(0, max_col - (self.width - 1)),
      top = math.max(0, -min_row),
      bottom = math.max(0, max_row - (self.height - 1)),
    }
  end

  ---Render one frame as virt_text overlay extmarks on the inline buffer's real
  ---text lines. Each maximal run of consecutive painted cells on a line becomes
  ---one extmark; empty cells are never painted, so artwork only ever overlays
  ---the exact cells it occupies and never fills a gap with a space that would
  ---erase the text underneath.
  ---@private
  function Model:_render_inline()
    local bufnr = self.inline_bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    -- Drop the previous frame before painting the next: the overlay has no
    -- fixed extmark id to update, so the frame is a fresh set of marks.
    self:_clear_inline()

    local view = self:_view()
    local origin_line, origin_col = self:_overlay_origin()
    self.overlay_row, self.overlay_col = origin_line, origin_col

    local raster = renderer.rasterize(self, view, self:_bleed(view))
    local segments = self:_build_overlay(bufnr, raster, origin_line, origin_col)

    if #segments > MAX_OVERLAY_EXMARKS then
      -- A full-footprint composite is too expensive; clip to the canvas, which
      -- produces far fewer segments, and tell the user once.
      self:_overlay_warn(
        ("wrfm: %s overflow=%s produces %d overlay segments (>%d); clipping to the canvas this frame"):format(
          tostring(self.id),
          self.overflow,
          #segments,
          MAX_OVERLAY_EXMARKS
        )
      )
      self:_clear_inline()
      segments = self:_build_overlay(bufnr, renderer.rasterize(self, view), origin_line, origin_col)
    end

    local ids = {}
    for _, seg in ipairs(segments) do
      local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, self.inline_ns, seg.line, seg.col, {
        virt_text = { { seg.text, "WrfmPreview" } },
        virt_text_pos = "overlay",
        hl_mode = "replace",
      })
      if ok then
        ids[#ids + 1] = id
      end
    end
    self.inline_extmark_ids = ids
  end

  ---Translate a raster into overlay segments: absolute cell grid cells for the
  ---buffers real lines, applying the natural boundaries (negative columns and
  ---rows outside the buffer are skipped) and, for `z_order = "text"`, skipping
  ---cells the buffer text already occupies.
  ---@private
  ---@param bufnr integer
  ---@param raster WrfmRaster
  ---@param origin_line integer buffer line of absolute cell row 0
  ---@param origin_col integer buffer column of absolute cell column 0
  ---@return { line: integer, col: integer, text: string }[]
  function Model:_build_overlay(bufnr, raster, origin_line, origin_col)
    local api = vim.api
    local line_count = api.nvim_buf_line_count(bufnr)
    local tabstop = vim.bo[bufnr].tabstop
    local skip_occupied = self.z_order == "text"
    local scans = {}
    local segments = {}

    local function line_scan(line)
      local s = scans[line]
      if not s then
        local text = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
        local occupied, byte_at = virtcol.scan(text, tabstop)
        s = { occupied = occupied, byte_at = byte_at }
        scans[line] = s
      end
      return s
    end

    for row = 0, raster.grid_h - 1 do
      local line = origin_line + raster.origin_row + row
      if line >= 0 and line < line_count then
        local scan = line_scan(line)
        local base = row * raster.grid_w
        local run_col, run_chars = nil, nil
        local flush = function()
          if run_chars then
            segments[#segments + 1] = {
              line = line,
              col = run_col,
              text = table.concat(run_chars),
            }
            run_chars = nil
          end
        end
        for col_idx = 1, raster.grid_w do
          local col = origin_col + raster.origin_col + (col_idx - 1)
          local val = raster.cells[base + col_idx]
          -- Natural boundaries (decision ①' / ⑥): a cell needs a column that
          -- exists on its line. `scan` leaves no entry for columns left of the
          -- buffer (negative), past the line's visual end, or inside a wide
          -- glyph or a tab, because an extmark may only start at a glyph
          -- boundary. Those columns cannot start a run; a cell the buffer
          -- already paints is dropped when `z_order = "text"`. Runs already
          -- open keep accumulating across non-startable columns, because the
          -- braille string lays out one cell per visual column and covers
          -- them; only the run's first cell needs a byte offset.
          local paint = val > 0
          if paint and skip_occupied and scan.occupied[col] then
            paint = false
          end
          if paint then
            if not run_chars then
              local byte_col = scan.byte_at[col]
              if byte_col ~= nil then
                run_col = byte_col
                run_chars = {}
              end
            end
            if run_chars then
              run_chars[#run_chars + 1] = renderer.cell_char(val)
            end
          else
            flush()
          end
        end
        flush()
      end
    end
    return segments
  end

  ---Delete every inline overlay extmark (no-op when none exists).
  ---@private
  function Model:_clear_inline()
    if self.inline_bufnr and vim.api.nvim_buf_is_valid(self.inline_bufnr) then
      for _, id in ipairs(self.inline_extmark_ids or {}) do
        pcall(vim.api.nvim_buf_del_extmark, self.inline_bufnr, self.inline_ns, id)
      end
    end
    self.inline_extmark_ids = nil
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
    local lines = renderer.render_frame(self, self:_view())
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
  ---cursor, or re-anchor the inline overlay to the new cursor line.
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
    local lines = renderer.render_frame(self, self:_view())
    local buf = api.nvim_win_get_buf(self.popup_winid)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(buf, self.inline_ns, 0, -1)
    for i = 0, #lines - 1 do
      api.nvim_buf_add_highlight(buf, self.inline_ns, "WrfmPreview", i, 0, -1)
    end
  end
end

return M
