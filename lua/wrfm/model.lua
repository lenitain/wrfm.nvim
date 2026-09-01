local parser = require("wrfm.parser")
local renderer = require("wrfm.renderer")
local term = require("wrfm.utils.term")
local window_util = require("wrfm.utils.window")

local uv = vim.uv or vim.loop

---@class WrfmVec3 : number[] # { x, y, z }
---@class WrfmEdge : number[] # { i, j } zero-based vertex indices

---Whether a model may paint outside its canvas (`overflow`).
---@alias WrfmOverflow "clip"|"visible"
---Who wins where a bleeding model and other cell occupants collide (`z_order`).
---@alias WrfmZOrder "model"|"text"

---@class WrfmModelOptions
---@field window? integer anchor float to this window instead of the editor grid
---@field buffer? integer paint into this buffer instead of a floating window
---@field width? integer canvas columns in braille cells
---@field height? integer canvas rows in braille cells
---@field x? integer horizontal offset from the centered placement (floats)
---@field y? integer vertical offset from the centered placement (floats)
---@field max_width_window_percentage? integer percentage width cap for this model
---@field max_height_window_percentage? integer percentage height cap for this model
---@field ignore_max_size? boolean lift percentage/absolute size caps for this model
---@field namespace? string registry tag for grouping/filtering
---@field distance? number camera distance (nil = auto fit)
---@field fov? number field of view in degrees (default from `default_fov`): how wide the camera looks, independent of how far it sits
---@field pitch? number initial pitch in degrees
---@field yaw? number initial yaw in degrees
---@field auto_spin? boolean start spinning right after render()
---@field spin_speed? number radians per frame
---@field pause_spin_when_unfocused? boolean pause auto-spin while the host
--   window is not focused (default: pause_spin_when_unfocused config)
---@field watch? boolean hot-reload the source file (default: default_watch)
---@field border? boolean float border and title (default true; false = seamless)
---@field overflow? WrfmOverflow inline: "visible" bleeds into surrounding text, "clip" truncates at canvas edge (default from `default_overflow`)
---@field z_order? WrfmZOrder how this model composites where it overlaps other cells (default from `default_z_order`)
---@field id? WrfmId stable registry identity (default "model-N")

---@class WrfmModelRestoreSnapshot
---@field modifiable boolean
---@field lines string[]

---@class WrfmModel
---@field path string source `.wrfm` file
---@field vertices WrfmVec3[] current geometry (replaced by hot reload)
---@field edges WrfmEdge[]
---@field width_opt? integer explicit width from options, if any
---@field height_opt? integer explicit height from options, if any
---@field x_off? integer offset from the centered column placement
---@field y_off? integer offset from the centered row placement
---@field max_w_pct? integer per-model percentage width cap
---@field max_h_pct? integer per-model percentage height cap
---@field ignore_max_size boolean size caps lifted for this model
---@field width? integer resolved canvas width
---@field height? integer resolved canvas height
---@field pitch number radians (display accumulator; `rot` is authoritative)
---@field yaw number radians (display accumulator; `rot` is authoritative)
---@field rot number[][] model->world orientation, 3x3 row-major (wireforge ViewState parity)
---@field dist_opt? number user-pinned camera distance
---@field fov number field of view in degrees (FOV frames the viewport, dist frames the model)
---@field fit_dist number auto-fit camera distance for the current geometry and view
---@field auto_spin boolean
---@field spin_speed number
---@field pause_spin_when_unfocused boolean spin pauses while the host window
--   is not focused
---@field watch boolean hot-reload enabled for this model
---@field border boolean float border/title enabled (seamless overlay when false)
---@field watch_started? boolean watcher is running
---@field anchor_win? integer anchored float target
---@field anchor_buf? integer buffer the anchor window showed at creation
---@field host_win? integer window that was focused at construction
---@field owns_buffer boolean true = we created (and may delete) the buffer
---@field bufnr? integer display or bound buffer
---@field winid? integer floating window, if open
---@field id? WrfmId registry identity (assigned by wrfm.from_file)
---@field timer? uv.uv_timer_t spin animation handle
---@field restore? WrfmModelRestoreSnapshot bound-buffer content snapshot
---@field watcher? uv.uv_fs_event_t directory watcher
---@field poll? uv.uv_fs_poll_t fallback file poller
---@field debounce? uv.uv_timer_t reload coalescing handle
---@field buf_watching? boolean buffer watcher attached (inline previews)
---@field buf_debounce? uv.uv_timer_t buffer-edit debounce handle
---@field last_text? string source text of the last successful parse (dual-channel dedup key)
---@field last_stat? { mtime: uv.uv_timeval64?, size?: integer } mtime/size dedup key
---@field reload_warned? boolean suppress duplicate reload warnings until recovery
---@field inline? boolean true = attached as inline preview (virt_text overlay)
---@field inline_bufnr? integer target buffer for inline (may differ from host buf)
---@field inline_ns integer extmark namespace (shared, set once by init)
---@field inline_extmark_ids? integer[] overlay extmark ids of the current frame
---@field only_render_at_cursor? boolean show preview only near cursor
---@field cursor_mode? "inline"|"popup" cursor-only rendering mode
---@field popup_winid? integer temporary cursor-popup window handle
---@field overlay_row? integer buffer line the canvas top-left cell mapped to last frame
---@field overlay_col? integer buffer column the canvas top-left cell mapped to last frame
---@field overflow WrfmOverflow inline overflow behavior (floats are always clipped)
---@field z_order WrfmZOrder overlap compositing intent (always consumed inline)
---@field namespace? string registry tag (assigned by wrfm.from_file)
---@field _moved? boolean user repositioned the float via move()
---@field _paint_pending? boolean a scheduled repaint is queued
---@field _overlay_warned? boolean an overlay degradation notice was already emitted
---@field _fit_geom? WrfmVec3[] geometry the cached extent was measured on
---@field _extent? number cached bounding-box extent (world units) of _fit_geom
local Model = {}
Model.__index = Model

---@param value unknown?
---@param fallback unknown
---@return unknown
local function opt(value, fallback)
  if value ~= nil then
    return value
  end
  return fallback
end

-- Values that select a rendering path, so a typo must not silently draw
-- something else. Compositing is always whole-cell: `model` paints over
-- the colliding cell, `text` skips it.
Model.OVERFLOWS = { clip = true, visible = true }
Model.Z_ORDERS = { model = true, text = true }

---Field of view bounds in degrees: focal = (viewport/2)/tan(fov/2) diverges at
---90 degrees and the framing degenerates near 0 or 180.
Model.FOV_MIN = 0.1
Model.FOV_MAX = 179.9

---Reject anything outside a numeric range (same boundary discipline as
---`check_enum`: a bad projection parameter raises where it is written down).
---@param value any
---@param name string option name quoted back in the error
---@param low number
---@param high number
---@return number value the validated value
---@throws when `value` is not a number inside `low`..`high`
function Model.check_range(value, name, low, high)
  -- `not (>= and <=)` instead of `< or >`: NaN compares false against
  -- everything, so a disjunction would wave it through into the projection.
  if type(value) ~= "number" or not (value >= low and value <= high) then
    return error(
      ("wrfm: %s must be a number from %s to %s, got %s"):format(
        name,
        tostring(low),
        tostring(high),
        vim.inspect(value)
      ),
      0
    )
  end
  return value
end

---Reject anything outside a fixed option set. Both `overflow` and `z_order`
---resolve from a per-model value over a global default, so each layer of the
---config is checked wherever it is written down.
---@param value any
---@param name string option name quoted back in the error
---@param allowed table<string, boolean>
---@return string value the validated value
---@throws when `value` is not one of `allowed`
function Model.check_enum(value, name, allowed)
  if allowed[value] then
    return value
  end
  local names = {}
  for option in pairs(allowed) do
    names[#names + 1] = '"' .. option .. '"'
  end
  table.sort(names)
  local last = table.remove(names)
  local legal = #names == 0 and last or (table.concat(names, ", ") .. " or " .. last)
  return error(("wrfm: %s must be %s, got %s"):format(name, legal, vim.inspect(value)), 0)
end

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high)
  return math.min(math.max(value, low), high)
end

---Dual-channel dedup key: buffer text carries no trailing newline while file
---text does; trailing whitespace carries no geometry meaning either way.
---@param text string
---@return string
local function text_key(text)
  return (text:gsub("%s+$", ""))
end

-- Deferred lookup: init.lua loads this module, so its config is read at
-- call time rather than load time.
---@return WrfmConfig
local function config()
  return require("wrfm").config
end

---@param winid integer?
---@return integer?
local function valid_anchor(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    return winid
  end
  return nil
end

---Resolve the canvas size in character cells.
---User-explicit dimensions (width_opt/height_opt) are respected as-is; only
---terminal bounds apply. Auto-derived dimensions go through percentage caps,
---absolute caps, and terminal bounds. ignore_max_size lifts percentage and
---absolute caps for auto-derived dimensions.
function Model:_resolve_size()
  if self.width and self.height then
    return
  end
  local cfg = config()
  local base = self:_base_window()
  local win_width, win_height = window_util.dimensions(base)
  local columns, lines = term.size()
  local max_w = math.max(columns - 2, 1)
  local max_h = math.max(lines - vim.o.cmdheight - 2, 1)

  local width, height
  if self.width_opt then
    width = self.width_opt
  else
    local pct_w = opt(self.max_w_pct, opt(cfg.max_width_window_percentage, 80))
    local capped_w = math.floor(win_width * pct_w / 100)
    width = opt(cfg.default_width, capped_w)
    if not self.ignore_max_size then
      width = math.min(width, capped_w)
      width = math.min(width, cfg.max_width or math.huge)
    end
  end

  if self.height_opt then
    height = self.height_opt
  else
    local pct_h = opt(self.max_h_pct, opt(cfg.max_height_window_percentage, 60))
    local capped_h = math.floor(win_height * pct_h / 100)
    height = opt(cfg.default_height, capped_h)
    if not self.ignore_max_size then
      height = math.min(height, capped_h)
      height = math.min(height, cfg.max_height or math.huge)
    end
  end

  self.width = clamp(width, 1, max_w)
  self.height = clamp(height, 1, max_h)
end

---@return boolean
function Model:_alive()
  local api = vim.api
  if not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then
    return false
  end
  if self.winid then
    return api.nvim_win_is_valid(self.winid) and api.nvim_win_get_buf(self.winid) == self.bufnr
  end
  return true
end

---The window this model lays itself out against: its anchor, the window focused
---at construction, or whatever is current once that window is gone.
---@private
---@return integer
function Model:_base_window()
  return valid_anchor(self.anchor_win)
    or valid_anchor(self.host_win)
    or vim.api.nvim_get_current_win()
end

---Dot height of the viewport whose FOV frames this model's render, or nil when
---the canvas is itself the viewport. Floats and cursor popups are the CLI
---semantics (the printed canvas *is* the screen, so framing follows the box).
---An in-buffer preview follows image.nvim's model: an object's physical size is
---set by its own camera, and the window only decides what is visible -- so the
---FOV subtends the editor screen, not the window. Resizing a split then reveals
---or crops the art instead of rescaling it, which also keeps the overlap
---geometry of `overflow = "visible"` stable across layout changes.
---@private
---@return integer?
function Model:_ref_height()
  if not self.inline or self:_uses_popup() then
    return nil
  end
  return term.text_lines() * 4
end

---The view this model renders right now: orientation, pinned-or-fitted camera
---distance, the resolved canvas and the viewport it is cropped from. Every
---render path reads it through here so a footprint query measures exactly what
---the next frame will draw.
---@private
---@return WrfmView
function Model:_view()
  self:_resolve_size()
  local px_h = self.height * 4
  local ref_h = self:_ref_height() or px_h
  -- Auto-fit belongs to the view, not to the geometry alone: it re-frames when
  -- the viewport, the canvas or the FOV changes. Only the bounding box costs
  -- anything, and it is invalidated by identity when a reload swaps vertices.
  if self._fit_geom ~= self.vertices then
    self._fit_geom = self.vertices
    self._extent = renderer.model_extent(self.vertices)
  end
  self.fit_dist = renderer.frame_distance(self._extent, ref_h, px_h, self.fov)
  return {
    rot = self.rot,
    dist = opt(self.dist_opt, self.fit_dist),
    width = self.width,
    height = self.height,
    ref_height = ref_h,
    fov_deg = self.fov,
  }
end

---The model's true display range for the current view, in absolute cells: what
---the rasterizer would paint on an unlimited grid. `overflow = "clip"` throws
---away whatever lands outside the canvas, so these numbers say how much.
---@return boolean occupied false = nothing reaches the screen
---@return integer min_col
---@return integer max_col
---@return integer min_row
---@return integer max_row
function Model:footprint()
  return renderer.footprint(self, self:_view())
end

---Whether the projected footprint reaches past the canvas. This is the design's
---`画布 < 显示范围` branch: `clip` truncates here, `visible` would overlap
---neighbouring cells and need `z_order` compositing.
---@return boolean
function Model:overflows()
  local any, min_col, max_col, min_row, max_row = self:footprint()
  if not any then
    return false
  end
  return min_col < 0 or max_col > self.width - 1 or min_row < 0 or max_row > self.height - 1
end

---Whether the window the user is looking at is the one this model decorates.
-- Out-of-focus models pause their spin (see pause_spin_when_unfocused)
-- instead of repainting an invisible frame every tick behind other windows
-- (a fullscreen Yazi/terminal float over the dashboard logo, a split taken
-- over by an editor, ...). Inline and bound models key off the buffer shown
-- in the current window; floats key off their anchor (or construction) window.
---@private
---@return boolean
function Model:_window_focused()
  local api = vim.api
  local current_buf = api.nvim_win_get_buf(api.nvim_get_current_win())
  if self.inline or not self.owns_buffer then
    return self.bufnr == current_buf
  end
  local host = valid_anchor(self.anchor_win) or valid_anchor(self.host_win)
  if not host then
    return false -- host window is gone; nothing to decorate
  end
  return api.nvim_get_current_win() == host
end

function Model:_ensure_window()
  local api = vim.api
  self:_resolve_size()
  if not (self.bufnr and api.nvim_buf_is_valid(self.bufnr)) then
    local buf = api.nvim_create_buf(false, true)
    local buf_opts = { buf = buf }
    api.nvim_set_option_value("buftype", "nofile", buf_opts)
    api.nvim_set_option_value("bufhidden", "wipe", buf_opts)
    api.nvim_set_option_value("swapfile", false, buf_opts)
    api.nvim_set_option_value("modifiable", false, buf_opts)
    pcall(api.nvim_buf_set_name, buf, "wrfm://" .. self.path)
    self.bufnr = buf
    self.owns_buffer = true
  end
  if
    self.winid
    and api.nvim_win_is_valid(self.winid)
    and api.nvim_win_get_buf(self.winid) == self.bufnr
  then
    return
  end
  self.winid = nil
  local win_config = window_util.float_config(
    self.width,
    self.height,
    valid_anchor(self.anchor_win),
    self.x_off,
    self.y_off
  )
  win_config.style = "minimal"
  -- A viewer never takes focus: it decorates the work the user is doing
  -- (dashboard art, preview panes). Close via :WrfmClear, not :q.
  win_config.focusable = false
  if self.border then
    win_config.border = "rounded"
    win_config.title = { { vim.fn.fnamemodify(self.path, ":t"), "Comment" } }
    win_config.title_pos = "center"
  else
    win_config.border = "none"
  end
  win_config.noautocmd = true
  self._moved = nil
  self.winid = api.nvim_open_win(self.bufnr, false, win_config)
  if not self.border then
    -- Seamless overlay (image.nvim look): frameless, background merged into
    -- the host window's Normal so only the braille art is visible.
    -- (winhighlight is a window option, not an nvim_open_win config key.)
    api.nvim_set_option_value(
      "winhighlight",
      "NormalFloat:Normal,FloatBorder:Normal",
      { win = self.winid }
    )
  end
end

---Repaint one frame into this model's buffer.
function Model:_paint()
  if not self:_alive() then
    return
  end
  local lines = renderer.render_frame(self, self:_view())
  local api = vim.api
  local buf_opts = { buf = self.bufnr }
  local was_modifiable = api.nvim_get_option_value("modifiable", buf_opts)
  api.nvim_set_option_value("modifiable", true, buf_opts)
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", was_modifiable, buf_opts)
  api.nvim_buf_clear_namespace(self.bufnr, self.inline_ns, 0, -1)
  for i = 0, #lines - 1 do
    api.nvim_buf_add_highlight(self.bufnr, self.inline_ns, "WrfmPreview", i, 0, -1)
  end
end

---Repaint one frame through the view mode's own channel so incremental
---updates never touch buffers the model does not own.
---Whether this model paints through the cursor popup window instead of the
---in-buffer extmark. A popup is a float of its own, so only a real in-buffer
---preview is a crop of the window it decorates.
---@private
---@return boolean
function Model:_uses_popup()
  return self.only_render_at_cursor and self.cursor_mode == "popup"
end

---@private
function Model:_repaint()
  if self.inline then
    if self:_uses_popup() then
      self:_repaint_popup()
    else
      self:_render_inline()
    end
  else
    self:_paint()
  end
end

---Relative (model-local) spin: post-multiplies the orientation matrix so the
---model turns around its own Y axis — wireforge's Space auto-spin. The yaw
---scalar only tracks the display angle, like wireforge's HUD.
---@private
---@param d number radians
function Model:_spin_local(d)
  self.rot = renderer.mat_mul(self.rot, renderer.rot_y(d))
  self.yaw = renderer.normalize_angle(self.yaw + d)
end

---Animation step: advance the local spin and repaint; tears down when the
---view died.
function Model:_tick()
  if not require("wrfm").enabled then
    -- Disabled globally; timers were already stopped by disable().
    return
  end
  -- Opening windows under the command-line window raises; skip this frame.
  if vim.fn.getcmdwintype() ~= "" then
    return
  end
  if not self:_alive() then
    self:clear()
    return
  end
  if self.pause_spin_when_unfocused and not self:_window_focused() then
    -- Host window lost focus: keep the timer (so spin resumes automatically
    -- when focus returns) but skip this frame's repaint entirely.
    return
  end
  self:_spin_local(self.spin_speed)
  self:_repaint()
end

function Model:_start_timer()
  local interval = math.max(1, math.floor(1000 / math.max(config().fps, 1)))
  self.timer = self.timer or uv.new_timer()
  self.timer:stop()
  self.timer:start(0, interval, function()
    -- Timer callbacks run outside fast-event context; defer to the main loop.
    vim.schedule(function()
      self:_tick()
    end)
  end)
end

---Load a `.wrfm` file; see `WrfmModelOptions` for the option surface.
---@param path string
---@param options WrfmModelOptions?
---@return WrfmModel
---@throws if the file cannot be read or does not parse
function Model.from_file(path, options)
  options = options or {}
  if options.buffer then
    vim.notify_once(
      "wrfm: from_file({ buffer = ... }) is deprecated; use wrfm.attach(bufnr) for non-destructive inline preview",
      vim.log.levels.WARN
    )
  end
  local handle, err = io.open(path, "r")
  if not handle then
    error(("wrfm: cannot read '%s': %s"):format(path, err or "?"), 0)
  end
  local text = handle:read("*a")
  handle:close()
  local data = parser.parse(text)
  local cfg = config()
  local pitch = math.rad(opt(options.pitch, cfg.default_pitch))
  local yaw = math.rad(opt(options.yaw, 0))
  local self = setmetatable({
    path = path,
    vertices = data.vertices,
    edges = data.edges,
    width_opt = options.width,
    height_opt = options.height,
    x_off = options.x,
    y_off = options.y,
    max_w_pct = options.max_width_window_percentage,
    max_h_pct = options.max_height_window_percentage,
    ignore_max_size = options.ignore_max_size == true,
    pitch = pitch,
    yaw = yaw,
    rot = renderer.rotation(pitch, yaw),
    dist_opt = opt(options.distance, cfg.default_distance),
    fov = Model.check_range(
      opt(options.fov, opt(cfg.default_fov, renderer.FOV_DEG)),
      "fov",
      Model.FOV_MIN,
      Model.FOV_MAX
    ),
    fit_dist = renderer.fit_distance(data.vertices),
    auto_spin = opt(options.auto_spin, cfg.default_auto_spin),
    spin_speed = opt(options.spin_speed, cfg.default_spin_speed),
    pause_spin_when_unfocused = opt(
      options.pause_spin_when_unfocused,
      cfg.pause_spin_when_unfocused
    ),
    watch = opt(options.watch, cfg.default_watch),
    border = opt(options.border, true),
    overflow = Model.check_enum(
      opt(options.overflow, opt(cfg.default_overflow, "clip")),
      "overflow",
      Model.OVERFLOWS
    ),
    z_order = Model.check_enum(
      opt(options.z_order, opt(cfg.default_z_order, "model")),
      "z_order",
      Model.Z_ORDERS
    ),
    anchor_win = options.window,
    anchor_buf = options.window
        and vim.api.nvim_win_is_valid(options.window)
        and vim.api.nvim_win_get_buf(options.window)
      or nil,
    host_win = vim.api.nvim_get_current_win(),
    owns_buffer = options.buffer == nil,
    bufnr = options.buffer,
    last_text = text_key(text),
  }, Model)
  return self
end

---Merge runtime geometry changes into the canvas size / float placement and
---resize a live float in place (image.nvim-style render(geometry) semantics).
---x/y are offsets from the centered placement; applying them overrides a
---manual move() position.
---@private
---@param geometry { width?: integer, height?: integer, x?: integer, y?: integer }
function Model:_apply_geometry(geometry)
  if
    geometry.width == nil
    and geometry.height == nil
    and geometry.x == nil
    and geometry.y == nil
  then
    return
  end
  local resized = false
  if geometry.width ~= nil or geometry.height ~= nil then
    if geometry.width ~= nil then
      self.width_opt = geometry.width
    end
    if geometry.height ~= nil then
      self.height_opt = geometry.height
    end
    self.width = nil
    self.height = nil
    self:_resolve_size()
    resized = true
  end
  local repositioned = false
  if geometry.x ~= nil or geometry.y ~= nil then
    if geometry.x ~= nil then
      self.x_off = geometry.x
    end
    if geometry.y ~= nil then
      self.y_off = geometry.y
    end
    -- Explicit offsets replace manual positioning.
    self._moved = nil
    repositioned = true
  end
  local api = vim.api
  if not (self.winid and api.nvim_win_is_valid(self.winid)) then
    return
  end
  if resized then
    pcall(api.nvim_win_set_config, self.winid, { width = self.width, height = self.height })
  end
  if repositioned then
    local win_config = window_util.float_config(
      self.width,
      self.height,
      valid_anchor(self.anchor_win),
      self.x_off,
      self.y_off
    )
    pcall(api.nvim_win_set_config, self.winid, {
      relative = win_config.relative,
      win = win_config.win,
      row = win_config.row,
      col = win_config.col,
    })
  end
end

---Draw the model (opening its float if needed) and arm auto-spin/watchers.
---When {geometry} is given, its width/height become the new canvas size and
---its x/y the new placement offset first. Before the UI exists
---(`vim_did_enter == 0`) rendering is queued until VimEnter instead: the
---terminal size that derived sizes clamp against is unknown earlier.
---@param geometry? { width?: integer, height?: integer, x?: integer, y?: integer }
---@return boolean false when rendering is globally disabled (silent no-op)
---   or when the draw was queued for VimEnter
---@throws in bound-buffer mode when the buffer is no longer valid
function Model:render(geometry)
  if vim.v.vim_did_enter == 0 then
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function()
        self:render(geometry)
      end,
    })
    return false
  end
  if not require("wrfm").enabled then
    return false
  end
  -- Opening windows under the command-line window raises inside scheduled
  -- callbacks where the error is hard to attribute; skip instead.
  if vim.fn.getcmdwintype() ~= "" then
    return false
  end
  if geometry then
    self:_apply_geometry(geometry)
  end
  if self.inline then
    if self:_uses_popup() then
      self:_render_popup()
    else
      self:_render_inline()
    end
  elseif self.owns_buffer then
    self:_ensure_window()
    self:_paint()
  else
    local api = vim.api
    if not (self.bufnr and api.nvim_buf_is_valid(self.bufnr)) then
      error("wrfm: bound buffer is not valid", 0)
    end
    if not self.restore then
      local buf_opts = { buf = self.bufnr }
      self.restore = {
        modifiable = api.nvim_get_option_value("modifiable", buf_opts),
        lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false),
      }
      self:_resolve_size()
    end
    self:_paint()
  end
  if self.auto_spin and self:_alive() then
    self:_start_timer()
  end
  if self.watch and not self.watch_started and self:_alive() then
    self:_start_watch()
  end
  if self.inline and self.watch and not self.buf_watching and self:_alive() then
    self:_start_buf_watch()
  end
  return true
end

---Shared teardown for clear() (full destroy) and hide() (keep registered).
---@param opts { destroy?: boolean } clear passes true
function Model:_teardown(opts)
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  self:_clear_inline()
  self:_close_popup()
  local api = vim.api
  if self.winid and api.nvim_win_is_valid(self.winid) then
    api.nvim_win_close(self.winid, true)
  end
  if self.bufnr then
    if self.owns_buffer then
      -- bufhidden=wipe can already have destroyed the scratch together with
      -- its window; drop the dangling handle either way so staleness sweeps
      -- cannot mistake a hidden model for a dead one.
      if api.nvim_buf_is_valid(self.bufnr) then
        api.nvim_buf_delete(self.bufnr, { force = true })
      end
      self.bufnr = nil
    elseif self.restore and api.nvim_buf_is_valid(self.bufnr) then
      local buf_opts = { buf = self.bufnr }
      api.nvim_buf_set_lines(self.bufnr, 0, -1, false, self.restore.lines)
      api.nvim_set_option_value("modifiable", self.restore.modifiable, buf_opts)
    end
  end
  -- enable()/show() re-render from a clean snapshot, so drop any restore
  -- state. Foreign (bound) buffers stay referenced across hide() so a later
  -- render() can repaint them; clear() releases the model's hold.
  self.restore = nil
  self.winid = nil
  -- A hidden model owns no timer; resume hooks must not resurrect one.
  self._focus_stopped = nil
  self._suspend_stopped = nil
  if opts and opts.destroy then
    self.bufnr = nil
    self:_stop_watch()
    require("wrfm")._unregister(self)
  end
end

---Destroy the view, stop timers/watchers, and unregister from the registry.
function Model:clear()
  self:_teardown({ destroy = true })
end

---Hide the view without unregistering: timers stop, floats close, bound
---buffers restore; camera/spin/watch state is preserved for show().
function Model:hide()
  self:_teardown({})
end

---Restore a hidden model. No-op when already visible; returns false while
---rendering is globally disabled.
---@return boolean
function Model:show()
  return self:render()
end

---Reposition the floating window to absolute editor coordinates.
---Only meaningful for float-mode models; inline and bound-buffer models are
---silent no-ops. Size, border and title are preserved.
---@param x integer column (0-based, editor-relative)
---@param y integer row (0-based, editor-relative)
function Model:move(x, y)
  local api = vim.api
  if not (self.winid and api.nvim_win_is_valid(self.winid)) then
    return
  end
  self._moved = true
  pcall(api.nvim_win_set_config, self.winid, { relative = "editor", row = y, col = x })
end

---Recompute derived canvas sizes after a resize. Models with both dimensions
-- passed explicitly keep their size; partially explicit models re-derive the
-- missing dimension only. Floats are moved/resized in place; bound-buffer
-- models just repaint at the new canvas size.
---@private
function Model:_relayout()
  -- A fixed canvas over a canvas-framed viewport (floats, bound buffers, popups)
  -- genuinely has nothing to redo. An in-buffer preview does: its projection is
  -- framed on the editor screen, so a screen resize changes the art even when
  -- the canvas was handed to us explicitly.
  if self.width_opt ~= nil and self.height_opt ~= nil and self:_ref_height() == nil then
    return
  end
  if not self:_alive() then
    return
  end
  self.width = nil
  self.height = nil
  self:_resolve_size()
  local api = vim.api
  if self.winid and api.nvim_win_is_valid(self.winid) then
    local win_config = window_util.float_config(
      self.width,
      self.height,
      valid_anchor(self.anchor_win),
      self.x_off,
      self.y_off
    )
    -- A user-moved float keeps its position; only the size follows the layout.
    if self._moved then
      win_config.relative = nil
      win_config.win = nil
      win_config.row = nil
      win_config.col = nil
    end
    pcall(api.nvim_win_set_config, self.winid, win_config)
  end
  self:_schedule_paint()
end

---Coalesce burst-triggered repaints into one scheduled draw: several events
---landing in the same event-loop turn (resize + hot reload) paint once.
---Routes through _repaint so inline previews never touch their host buffer.
---@private
function Model:_schedule_paint()
  if self._paint_pending then
    return
  end
  self._paint_pending = true
  vim.schedule(function()
    self._paint_pending = false
    self:_repaint()
  end)
end

---Toggle auto-spin; without an argument, invert the current state.
---@param enabled boolean?
function Model:set_spin(enabled)
  if enabled == nil then
    enabled = not self.auto_spin
  end
  self.auto_spin = enabled and true or false
  if self.auto_spin then
    if self:_alive() then
      self:_start_timer()
    end
  elseif self.timer then
    self.timer:stop()
  end
end

---Tilt the view to {degrees} (display angle) with a world-frame delta
---rotation, matching wireforge's arrow-key pitch, and repaint.
---@param degrees number
function Model:set_pitch(degrees)
  local delta = math.rad(degrees) - self.pitch
  self.rot = renderer.mat_mul(renderer.rot_x(delta), self.rot)
  self.pitch = renderer.normalize_angle(math.rad(degrees))
  if self:_alive() then
    self:_repaint()
  end
end

---Pin the camera distance (nil restores auto-fit) and repaint.
---@param distance number?
function Model:set_distance(distance)
  self.dist_opt = distance
  if self:_alive() then
    self:_repaint()
  end
end

---Set the field of view in degrees and repaint. FOV decides how much of the
---world the viewport shows; `set_distance` decides how far away the model sits
---and therefore how strong the perspective is. Together they size the art
---without dragging the projection along.
---@param degrees number
function Model:set_fov(degrees)
  self.fov = Model.check_range(degrees, "fov", Model.FOV_MIN, Model.FOV_MAX)
  if self:_alive() then
    self:_repaint()
  end
end

require("wrfm.inline").mixin(Model)
require("wrfm.watcher").mixin(Model)

return Model
