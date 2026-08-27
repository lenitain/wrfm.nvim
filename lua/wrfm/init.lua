local Model = require("wrfm.model")

---Stable model identity assigned by wrfm.from_file.
---@alias WrfmId string

---@class WrfmConfig
---@field default_width? integer canvas columns (nil = 80% of the host window)
---@field default_height? integer canvas rows (nil = 60% of the host window)
---@field max_width? integer canvas columns hard cap (nil = unlimited)
---@field max_height? integer canvas rows hard cap (nil = unlimited)
---@field max_width_window_percentage? integer percentage width cap for auto-derived sizes (default 80)
---@field max_height_window_percentage? integer percentage height cap for auto-derived sizes (default 60)
---@field default_overflow "visible"|"clip" inline overflow: visible bleeds into text, clip truncates at canvas edge
---@field default_pitch number initial pitch in degrees
---@field default_distance? number camera distance (nil = auto fit)
---@field default_auto_spin boolean spin by default after render()
---@field default_spin_speed number radians per frame
---@field default_watch boolean hot-reload source files by default
---@field pause_spin_when_unfocused boolean pause auto-spin while the model's
--   host window is not focused (default true)
---@field fps number animation frame rate
---@field integrations WrfmIntegrationConfig

---@class WrfmModelQuery
---@field window? integer match models whose float is this window
---@field buffer? integer match models bound to this buffer
---@field namespace? string match models carrying this registry tag

local M = { current = nil }

---@type integer extmark namespace shared by all inline previews
M.inline_ns = vim.api.nvim_create_namespace("wrfm-inline")

local KNOWN_KEYS = {
  default_width = true,
  default_height = true,
  max_width = true,
  max_height = true,
  max_width_window_percentage = true,
  max_height_window_percentage = true,
  default_overflow = true,
  default_pitch = true,
  default_distance = true,
  default_auto_spin = true,
  default_spin_speed = true,
  default_watch = true,
  pause_spin_when_unfocused = true,
  fps = true,
  integrations = true,
}

local KNOWN_INTEGRATION_KEYS = {
  enabled = true,
  clear_in_insert_mode = true,
  only_render_at_cursor = true,
  cursor_mode = true,
  filetypes = true,
}

-- Defaults live in a plain data table so setup() can validate keys without
-- mistaking legitimate nil values (default_width etc.) for typos.
---@type WrfmConfig
M.config = {
  default_width = nil,
  default_height = nil,
  max_width = nil,
  max_height = nil,
  max_width_window_percentage = 80,
  max_height_window_percentage = 60,
  default_overflow = "clip",
  default_pitch = 23,
  default_distance = nil,
  default_auto_spin = true,
  default_spin_speed = 0.02,
  default_watch = true,
  -- A spinning model repaints its buffer every frame; when the window it
  -- decorates loses focus (a fullscreen Yazi/terminal float over the
  -- dashboard, a split taken over by an editor), that repaint is invisible
  -- but still burns CPU and redraws. Pause the spin until focus returns.
  pause_spin_when_unfocused = true,
  fps = 60,
  integrations = {
    wrfm = {
      enabled = true,
      clear_in_insert_mode = false,
      only_render_at_cursor = false,
      cursor_mode = "popup",
      filetypes = { "wrfm" },
    },
  },
}

-- Sentinel augroups live above setup(): its integrations branch invalidates
-- them so the next _ensure_integration_hooks() re-registers with new patterns.
-- Resize hooks register lazily when the first model appears: this plugin's
-- setup() is optional, so registration cannot depend on it (this deliberately
-- differs from image.nvim, which hooks in setup()).
local resize_augroup = nil
-- Integration hooks (FileType auto-attach etc.) register at load time via
-- the plugin/ entry.
local integration_augroup = nil
-- True while the cursor-follow hooks (CursorMoved -> _follow_cursor) are
-- registered; popup rendering consults it to skip its one-shot self-destruct.
local cursor_follow_armed = false

---Merge into the current defaults; unknown keys raise to catch typos.
---@param options WrfmConfig?
function M.setup(options)
  options = options or {}
  for key in pairs(options) do
    if not KNOWN_KEYS[key] then
      error(("wrfm.setup: unknown option '%s'"):format(key), 0)
    end
  end
  for key, value in pairs(options) do
    if key == "integrations" and type(value) == "table" then
      for sub_key, sub_value in pairs(value) do
        if sub_key == "wrfm" and type(sub_value) == "table" then
          for integration_key in pairs(sub_value) do
            if not KNOWN_INTEGRATION_KEYS[integration_key] then
              error(("wrfm.setup: unknown integration option '%s'"):format(integration_key), 0)
            end
          end
          M.config.integrations.wrfm =
            vim.tbl_deep_extend("force", M.config.integrations.wrfm, sub_value)
          -- Drop hooks registered with the previous patterns; the next
          -- _ensure_integration_hooks() rebuilds them from the new config.
          integration_augroup = nil
          cursor_follow_armed = false
        else
          error(("wrfm.setup: unknown integration '%s'"):format(sub_key), 0)
        end
      end
    else
      ---@diagnostic disable-next-line: param-type-mismatch
      M.config[key] = value
    end
  end
end

-- ---------------------------------------------------------------------------
-- Registry: every model created through from_file() lives here until clear().
-- ---------------------------------------------------------------------------

---@type WrfmModel[] ordered array of live models
M.models = {}

---@type boolean global render switch (see enable/disable/is_enabled)
M.enabled = true

local next_id = 0

---Whether the cursor-follow hooks are currently registered.
---@private
---@return boolean
function M._cursor_follow_armed()
  return cursor_follow_armed
end

function M._ensure_resize_hooks()
  if resize_augroup then
    return
  end
  resize_augroup = vim.api.nvim_create_augroup("wrfm.resize", { clear = true })
  local function relayout_all()
    for _, model in ipairs({ unpack(M.models) }) do
      model:_relayout()
    end
  end
  vim.api.nvim_create_autocmd("VimResized", {
    group = resize_augroup,
    callback = vim.schedule_wrap(relayout_all),
  })
  -- WinResized only matters for anchored floats whose anchor window changed.
  vim.api.nvim_create_autocmd("WinResized", {
    group = resize_augroup,
    callback = vim.schedule_wrap(function(event)
      local resized = (event.data and event.data.windows) or vim.v.event.windows or {}
      for _, model in ipairs({ unpack(M.models) }) do
        if model.anchor_win and vim.tbl_contains(resized, model.anchor_win) then
          model:_relayout()
        end
      end
    end),
  })
end

-- Spin timers pause when the editor loses focus or is suspended, and resume
-- on the mirror events. Only timers are touched: braille frames cost nothing
-- to leave on screen, and the *_stopped markers keep manually stopped spins
-- from being resurrected. Registered lazily alongside the resize hooks so it
-- covers every model regardless of integration settings.
local lifecycle_augroup = nil

function M._ensure_lifecycle_hooks()
  if lifecycle_augroup then
    return
  end
  lifecycle_augroup = vim.api.nvim_create_augroup("wrfm.lifecycle", { clear = true })

  ---@param flag "_focus_stopped"|"_suspend_stopped"
  local function pause_timers(flag)
    for _, model in ipairs(M.models) do
      if model.timer and model.timer:is_active() then
        model.timer:stop()
        model[flag] = true
      end
    end
  end

  ---@param flag "_focus_stopped"|"_suspend_stopped"
  local function resume_timers(flag)
    for _, model in ipairs({ unpack(M.models) }) do
      if model[flag] then
        model[flag] = nil
        -- disable() owns timer state while rendering is switched off.
        if M.enabled and model.auto_spin and model:_alive() then
          model:_start_timer()
        end
      end
    end
  end

  vim.api.nvim_create_autocmd("FocusLost", {
    group = lifecycle_augroup,
    callback = function()
      pause_timers("_focus_stopped")
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = lifecycle_augroup,
    callback = function()
      resume_timers("_focus_stopped")
    end,
  })
  vim.api.nvim_create_autocmd("VimSuspend", {
    group = lifecycle_augroup,
    callback = function()
      pause_timers("_suspend_stopped")
    end,
  })
  vim.api.nvim_create_autocmd("VimResume", {
    group = lifecycle_augroup,
    callback = function()
      resume_timers("_suspend_stopped")
    end,
  })

  -- Stale-context sweep: contexts that vanished (closed window, deleted
  -- buffer, anchor window showing other content) take their models with
  -- them. This is the only teardown path for non-spinning models, which no
  -- tick ever asks _alive() for.
  local function sweep_stale()
    local api = vim.api
    for _, model in ipairs({ unpack(M.models) }) do
      if model.inline then
        if not (model.inline_bufnr and api.nvim_buf_is_valid(model.inline_bufnr)) then
          model:clear()
        end
      elseif model.winid then
        -- User-closed window / float buffer swapped out: same semantics as
        -- the _tick self-teardown.
        if
          not api.nvim_win_is_valid(model.winid)
          or api.nvim_win_get_buf(model.winid) ~= model.bufnr
        then
          model:clear()
        elseif model.anchor_win then
          -- Anchored overlay decorating a host window that died or switched
          -- content would keep covering unrelated text.
          local host_gone = not api.nvim_win_is_valid(model.anchor_win)
            or api.nvim_win_get_buf(model.anchor_win) ~= model.anchor_buf
          if host_gone then
            model:clear()
          end
        end
      elseif model.bufnr and not api.nvim_buf_is_valid(model.bufnr) then
        model:clear() -- bound mode: host buffer deleted
      end
    end
  end
  vim.api.nvim_create_autocmd({ "TabEnter", "BufEnter", "WinClosed" }, {
    group = lifecycle_augroup,
    callback = vim.schedule_wrap(sweep_stale),
  })
end

---@private
---@param model WrfmModel
function M._register(model)
  M.models[#M.models + 1] = model
  M._ensure_resize_hooks()
  M._ensure_lifecycle_hooks()
end

---@private
---@param model WrfmModel
function M._unregister(model)
  for index, registered in ipairs(M.models) do
    if registered == model then
      table.remove(M.models, index)
      if M.current == model then
        M.current = nil
      end
      return
    end
  end
end

---Load a `.wrfm` file into a new registered model and make it `current`.
---See `WrfmModelOptions` for the option surface; an id is assigned here
---(`options.id` or "model-N"). Passing an `options.id` that is already live
---returns the existing model as-is (other options in that call are ignored).
---@param path string
---@param options WrfmModelOptions?
---@return WrfmModel
---@throws if the file cannot be read or does not parse
function M.from_file(path, options)
  options = options or {}
  -- image.nvim semantics: a live model carrying the requested id is reused
  -- as-is; every other option in this call is ignored.
  if options.id then
    for _, model in ipairs(M.models) do
      if model.id == options.id then
        M.current = model
        return model
      end
    end
  end
  next_id = next_id + 1
  local id = options.id or ("model-" .. next_id)
  local model = Model.from_file(path, options)
  model.id = id
  model.namespace = options.namespace
  model.inline_ns = M.inline_ns
  M.current = model
  M._register(model)
  return model
end

---Live models, optionally filtered: `opts.window` matches the rendered float
---window, `opts.buffer` the bound buffer, `opts.namespace` the registry tag;
---filters combine conjunctively.
---@param opts WrfmModelQuery?
---@return WrfmModel[]
function M.get_models(opts)
  opts = opts or {}
  local result = {}
  for _, model in ipairs(M.models) do
    local window_match = opts.window == nil or model.winid == opts.window
    local buffer_match = opts.buffer == nil
      or model.bufnr == opts.buffer
      or model.inline_bufnr == opts.buffer
    local namespace_match = opts.namespace == nil or model.namespace == opts.namespace
    if window_match and buffer_match and namespace_match then
      result[#result + 1] = model
    end
  end
  return result
end

---Destroy the model with id `id`; without an argument, destroy all models.
---Every model matching `id` is destroyed (defensive: the registry may hold
---duplicates built outside from_file's reuse path).
---@param id WrfmId?
function M.clear(id)
  if id == nil then
    for index = #M.models, 1, -1 do
      M.models[index]:clear()
    end
    return
  end
  -- Reverse walk: clear() unregisters models while we iterate.
  for index = #M.models, 1, -1 do
    if M.models[index].id == id then
      M.models[index]:clear()
    end
  end
end

---Hide every view (or just the model with id `id`) without unregistering;
---show() restores them. Camera/spin/watch state is preserved.
---@param id WrfmId?
function M.hide(id)
  for _, model in ipairs(M.models) do
    if id == nil or model.id == id then
      model:hide()
    end
  end
end

---Restore hidden models (all of them, or one by id); mirrors M.hide.
---@param id WrfmId?
function M.show(id)
  for _, model in ipairs({ unpack(M.models) }) do
    if id == nil or model.id == id then
      model:render()
    end
  end
end

---Re-enable rendering and rebuild every live model's view.
function M.enable()
  M.enabled = true
  for _, model in ipairs({ unpack(M.models) }) do
    model:render()
  end
end

---Stop timers, hide every view, restore bound buffers; models stay registered
---so enable() can bring them back unchanged. While disabled, render() is a
---silent no-op returning false.
function M.disable()
  M.enabled = false
  for _, model in ipairs({ unpack(M.models) }) do
    model:hide()
  end
end

function M._ensure_integration_hooks()
  if integration_augroup then
    return
  end
  local cfg = M.config.integrations.wrfm
  if not cfg.enabled then
    return
  end
  integration_augroup = vim.api.nvim_create_augroup("wrfm.integrations", { clear = true })
  cursor_follow_armed = false
  vim.api.nvim_create_autocmd("FileType", {
    group = integration_augroup,
    pattern = cfg.filetypes,
    callback = function(args)
      local bufnr = args.buf
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path == "" then
        return
      end
      local ok, err = pcall(M.attach, bufnr, { path = path })
      if not ok then
        vim.notify_once("wrfm: auto-attach failed: " .. tostring(err), vim.log.levels.WARN)
      end
    end,
  })
  if cfg.only_render_at_cursor then
    -- Cursor-follow: cursor-only previews re-anchor on every move instead of
    -- closing on the first one (the popup's one-shot self-destruct stands
    -- down while this is armed).
    cursor_follow_armed = true
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = integration_augroup,
      pattern = cfg.filetypes,
      callback = function(args)
        for _, model in ipairs(M.get_models({ buffer = args.buf })) do
          if model.inline and model.only_render_at_cursor then
            model:_follow_cursor()
          end
        end
      end,
    })
  end
  if cfg.clear_in_insert_mode then
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = integration_augroup,
      pattern = cfg.filetypes,
      callback = function(args)
        for _, model in ipairs(M.get_models({ buffer = args.buf })) do
          if model.inline then
            model:_clear_inline()
            model:_close_popup()
          end
        end
      end,
    })
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = integration_augroup,
      pattern = cfg.filetypes,
      callback = function(args)
        for _, model in ipairs(M.get_models({ buffer = args.buf })) do
          if model.inline then
            model:render()
          end
        end
      end,
    })
  end
end

---Attach a live inline preview to `bufnr`. The buffer must already have a
---filepath (used to locate the `.wrfm` source); pass `path` to override.
---Attaching to a buffer that already carries an inline preview re-renders it
---instead of stacking a second one.
---@param bufnr integer
---@param opts? WrfmModelOptions
---@return WrfmModel
function M.attach(bufnr, opts)
  opts = opts or {}
  -- Already attached: re-render instead of stacking a second extmark/timer.
  for _, model in ipairs(M.get_models({ buffer = bufnr })) do
    if model.inline then
      model:render()
      return model
    end
  end
  local path = opts.path or vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    error("wrfm.attach: buffer has no file name; pass opts.path", 0)
  end
  local int_cfg = M.config.integrations.wrfm
  local model = M.from_file(path, opts)
  model.inline = true
  model.inline_bufnr = bufnr
  model.inline_ns = M.inline_ns
  model.owns_buffer = false
  model.bufnr = bufnr
  model.only_render_at_cursor = opts.only_render_at_cursor
  if model.only_render_at_cursor == nil then
    model.only_render_at_cursor = int_cfg.only_render_at_cursor
  end
  model.cursor_mode = opts.cursor_mode or int_cfg.cursor_mode
  M._ensure_integration_hooks()
  model:render()
  return model
end

---Detach all inline previews from `bufnr`.
---@param bufnr integer
function M.detach(bufnr)
  for i = #M.models, 1, -1 do
    local model = M.models[i]
    if model.inline and model.inline_bufnr == bufnr then
      model:clear()
    end
  end
end

---@return boolean
function M.is_enabled()
  return M.enabled
end

return M
