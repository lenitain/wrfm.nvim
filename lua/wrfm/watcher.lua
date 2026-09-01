local parser = require("wrfm.parser")

local uv = vim.uv or vim.loop

local RELOAD_DEBOUNCE_MS = 150
local POLL_INTERVAL_MS = 2000

---Dual-channel dedup key: buffer text carries no trailing newline while file
---text does; trailing whitespace carries no geometry meaning either way.
---@param text string
---@return string
local function text_key(text)
  return (text:gsub("%s+$", ""))
end

---@param stat uv.fs_stat_result?
---@return string?
local function stat_key(stat)
  return stat and table.concat({ stat.mtime.sec, stat.mtime.nsec, stat.size }, ":") or nil
end

local M = {}

---@param Model table Model's metatable
function M.mixin(Model)
  ---Watch the model's parent directory (robust against editors replacing the
  -- file by rename); falls back to polling the file itself when fs_event is
  -- unavailable (some filesystems/containers).
  ---@private
  function Model:_start_watch()
    if self.watch_started or not self.path then
      return
    end
    self.watch_started = true
    local path = vim.fs.normalize(self.path)
    local dir = vim.fs.dirname(path)
    local name = vim.fn.fnamemodify(path, ":t")

    local event = uv.new_fs_event()
    local started = pcall(function()
      event:start(dir, {}, function(_, filename)
        if filename == nil or filename == name then
          self:_queue_reload()
        end
      end)
    end)
    if started then
      self.watcher = event
    else
      event:close()
      local poll = uv.new_fs_poll()
      local poll_ok = pcall(function()
        poll:start(path, POLL_INTERVAL_MS, function()
          self:_queue_reload()
        end)
      end)
      if not poll_ok then
        -- Neither mechanism available: degrade to a static snapshot.
        poll:close()
        self.watch_started = false
        return
      end
      self.poll = poll
    end

    local stat = uv.fs_stat(path)
    self.last_stat = stat and { mtime = stat.mtime, size = stat.size } or nil
  end

  ---Close all watcher machinery; safe to call repeatedly.
  ---@private
  function Model:_stop_watch()
    self.watch_started = false
    if self.debounce then
      self.debounce:stop()
      self.debounce:close()
      self.debounce = nil
    end
    if self.watcher then
      pcall(function()
        self.watcher:stop()
      end)
      self.watcher:close()
      self.watcher = nil
    end
    if self.poll then
      pcall(function()
        self.poll:stop()
      end)
      self.poll:close()
      self.poll = nil
    end
    if self.buf_watching then
      self.buf_watching = nil -- on_detach re-sets this; clear first either way
      if self.inline_bufnr and vim.api.nvim_buf_is_valid(self.inline_bufnr) then
        pcall(vim.api.nvim_buf_detach, self.inline_bufnr)
      end
    end
    if self.buf_debounce then
      self.buf_debounce:stop()
      self.buf_debounce:close()
      self.buf_debounce = nil
    end
    self.reload_warned = false
  end

  ---Debounce fs events with one restartable timer handle.
  ---@private
  function Model:_queue_reload()
    if not self.watch_started then
      return
    end
    local timer = self.debounce
    if not timer then
      timer = uv.new_timer()
      self.debounce = timer
    end
    timer:stop()
    timer:start(RELOAD_DEBOUNCE_MS, 0, function()
      -- Timer callbacks run outside fast-event context; defer to the main loop.
      vim.schedule(function()
        self:_reload()
      end)
    end)
  end

  ---Attach an on_lines watcher to the inline buffer (edit-mode live preview).
  ---@private
  function Model:_start_buf_watch()
    if self.buf_watching or not (self.inline and self.inline_bufnr) then
      return
    end
    local ok = vim.api.nvim_buf_attach(self.inline_bufnr, false, {
      on_lines = function()
        self:_queue_buf_reload()
        -- Returning truthy would detach; stay attached.
        return false
      end,
      on_detach = function()
        self.buf_watching = nil
        if self.buf_debounce then
          self.buf_debounce:stop()
          self.buf_debounce:close()
          self.buf_debounce = nil
        end
      end,
    })
    if ok then
      self.buf_watching = true
    end
  end

  ---Debounce on_lines bursts with an independent restartable timer.
  ---@private
  function Model:_queue_buf_reload()
    if not self.buf_watching then
      return
    end
    local timer = self.buf_debounce
    if not timer then
      timer = uv.new_timer()
      self.buf_debounce = timer
    end
    timer:stop()
    timer:start(RELOAD_DEBOUNCE_MS, 0, function()
      vim.schedule(function()
        self:_buf_reload()
      end)
    end)
  end

  ---Re-parse the inline buffer's unsaved content: swap geometry on success,
  ---warn once and keep the last frame on parse failures.
  ---@private
  function Model:_buf_reload()
    if not self.buf_watching then
      return
    end
    local bufnr = self.inline_bufnr
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
      return
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    local key = text_key(text)
    if self.last_text and key == self.last_text then
      return -- edit reconstructed the already-shown content (e.g. undo)
    end
    local ok, data = pcall(parser.parse, text)
    if not ok then
      -- Mid-edit states parse as garbage; keep showing the last good frame.
      self:_reload_warn(
        ("wrfm: buffer edit failed to parse (%s), keeping last view"):format(tostring(data))
      )
      return
    end
    -- Swap geometry atomically; view state is preserved across reloads. The new
    -- vertices table alone invalidates the cached fit distance in Model:_view().
    self.vertices = data.vertices
    self.edges = data.edges
    self.last_text = key
    self.reload_warned = false
    self:_schedule_paint()
  end

  ---@private
  ---@param msg string
  function Model:_reload_warn(msg)
    if not self.reload_warned then
      self.reload_warned = true
      vim.notify_once(msg, vim.log.levels.WARN)
    end
  end

  ---Re-read the source file: swap geometry on success, warn once and keep the
  ---last frame on parse failures, stop watching if the file disappeared.
  ---@private
  function Model:_reload()
    if not self.watch_started then
      return
    end
    local path = vim.fs.normalize(self.path)
    local stat = uv.fs_stat(path)
    if not stat then
      self:_reload_warn(("wrfm: model file disappeared, keeping last view: %s"):format(path))
      self:_stop_watch()
      return
    end
    if
      self.last_stat
      and stat_key(stat) == stat_key({ mtime = self.last_stat.mtime, size = self.last_stat.size })
    then
      return
    end
    local handle, err = io.open(path, "r")
    if not handle then
      self:_reload_warn(("wrfm: cannot reread '%s': %s"):format(path, err or "?"))
      return
    end
    local text = handle:read("*a")
    handle:close()
    local key = text_key(text)
    if self.last_text and key == self.last_text then
      -- The buffer channel already showed this content (:write echo); only
      -- refresh the stat key so later real changes still register.
      self.last_stat = { mtime = stat.mtime, size = stat.size }
      return
    end
    local ok, data = pcall(parser.parse, text)
    if not ok then
      -- Mid-edit states parse as garbage; keep showing the last good frame.
      self:_reload_warn(
        ("wrfm: reload of '%s' failed (%s), keeping last view"):format(path, tostring(data))
      )
      return
    end
    -- Swap geometry atomically; every view state (pitch/yaw/dist/spin/id/
    -- bindings) is deliberately preserved across reloads. The new vertices table
    -- invalidates the cached fit distance in Model:_view() by identity.
    self.vertices = data.vertices
    self.edges = data.edges
    self.last_text = key
    self.last_stat = { mtime = stat.mtime, size = stat.size }
    self.reload_warned = false
    self:_schedule_paint()
  end
end

return M
