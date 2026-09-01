-- Diagnostic report: system info plus a live snapshot of every registered
-- model. Plain text lines so both :WrfmReport and scripts can consume it.

local M = {}

---@return string
local function version_line()
  local version = vim.version()
  return ("neovim: %d.%d.%d"):format(version.major, version.minor, version.patch)
end

---@return string
local function platform_line()
  local uv = vim.uv or vim.loop
  local ok, uname = pcall(uv.os_uname)
  if ok and uname and uname.sysname then
    return ("platform: %s %s (%s)"):format(uname.sysname, uname.release, uname.machine)
  end
  return "platform: unknown"
end

---@param value number? radians
---@return string degrees or "-"
local function degrees(value)
  if value == nil then
    return "-"
  end
  return ("%.0f"):format(math.deg(value))
end

---@return string[]
local function config_lines()
  local cfg = require("wrfm").config
  return {
    ("config: fps=%s default_pitch=%s default_fov=%s default_distance=%s default_auto_spin=%s default_spin_speed=%s default_watch=%s"):format(
      tostring(cfg.fps),
      tostring(cfg.default_pitch),
      tostring(cfg.default_fov),
      tostring(cfg.default_distance),
      tostring(cfg.default_auto_spin),
      tostring(cfg.default_spin_speed),
      tostring(cfg.default_watch)
    ),
    ("config: default_size=%sx%s integrations.wrfm.enabled=%s cursor_mode=%s only_render_at_cursor=%s clear_in_insert_mode=%s"):format(
      tostring(cfg.default_width),
      tostring(cfg.default_height),
      tostring(cfg.integrations.wrfm.enabled),
      tostring(cfg.integrations.wrfm.cursor_mode),
      tostring(cfg.integrations.wrfm.only_render_at_cursor),
      tostring(cfg.integrations.wrfm.clear_in_insert_mode)
    ),
    ("config: default_overflow=%s default_z_order=%s"):format(
      tostring(cfg.default_overflow),
      tostring(cfg.default_z_order)
    ),
    ("config: max_width=%s max_height=%s max_width_window_percentage=%s%% max_height_window_percentage=%s%%"):format(
      tostring(cfg.max_width),
      tostring(cfg.max_height),
      tostring(cfg.max_width_window_percentage),
      tostring(cfg.max_height_window_percentage)
    ),
  }
end

---One snapshot line per live model, mirroring the :WrfmList shape but with
---the full camera/lifecycle state.
---@return string[]
local function model_lines()
  local models = require("wrfm").get_models()
  if #models == 0 then
    return { "models: none live" }
  end
  local lines = { ("models: %d live"):format(#models) }
  for _, model in ipairs(models) do
    local mode = model.inline and "inline" or model.winid and "float" or "bound"
    local spinning = model.timer and model.timer:is_active() or false
    local dist = model.dist_opt ~= nil and ("%.2f"):format(model.dist_opt)
      or ("auto %.2f"):format(model.fit_dist)
    local channel = model.inline and model:_render_channel() or "-"
    lines[#lines + 1] = ("  %s [%s] %s %sx%s ref=%sd fov=%s overflow=%s truncated=%s z_order=%s channel=%s pitch=%s yaw=%s dist=%s spin=%s speed=%.3f watch=%s buf=%s win=%s | %s"):format(
      tostring(model.id),
      mode,
      model.namespace or "-",
      tostring(model.width),
      tostring(model.height),
      tostring(model:_view().ref_height),
      tostring(model.fov),
      model.overflow,
      tostring(model:overflows()),
      model.z_order,
      channel,
      degrees(model.pitch),
      degrees(model.yaw),
      dist,
      tostring(spinning),
      model.spin_speed,
      tostring(model.watch_started == true),
      tostring(model.bufnr),
      tostring(model.winid),
      model.path
    )
  end
  return lines
end

---@return string[]
local function resource_lines()
  local timers, watchers = 0, 0
  for _, model in ipairs(require("wrfm").get_models()) do
    if model.timer and model.timer:is_active() then
      timers = timers + 1
    end
    if model.watcher or model.poll then
      watchers = watchers + 1
    end
  end
  local cli = vim.fn.executable("wrfm") == 1 and "found"
    or "not on PATH (only needed for `mise run golden`)"
  return {
    ("resources: active spin timers=%d file watchers=%d"):format(timers, watchers),
    ("wrfm CLI: %s"):format(cli),
  }
end

---Build the diagnostic report lines.
---@return string[] one entry per output line
function M.generate()
  local lines = {
    version_line(),
    platform_line(),
  }
  vim.list_extend(lines, config_lines())
  vim.list_extend(lines, model_lines())
  vim.list_extend(lines, resource_lines())
  return lines
end

return M
