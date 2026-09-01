-- :checkhealth wrfm — pure-function probes only (parser/renderer/timer), so
-- the report works in headless environments without touching window APIs.

local M = {}

local MIN_NVIM = { 0, 11, 0 }

local CUBE = [[
wrfm 1
vertices 8 edges 12
v -1 -1 -1
v 1 -1 -1
v 1 1 -1
v -1 1 -1
v -1 -1 1
v 1 -1 1
v 1 1 1
v -1 1 1
e 0 1
e 1 2
e 2 3
e 3 0
e 4 5
e 5 6
e 6 7
e 7 4
e 0 4
e 1 5
e 2 6
e 3 7
]]

local function contains_braille(text)
  for i = 1, #text - 2 do
    if text:byte(i) == 0xE2 and text:byte(i + 1) >= 0xA0 and text:byte(i + 1) <= 0xA3 then
      return true
    end
  end
  return false
end

function M.check()
  local health = vim.health
  health.start("wrfm")

  -- 1. Neovim version floor (kept in sync with README Requirements and CI).
  local version = vim.version()
  if vim.version.ge(version, MIN_NVIM) then
    health.ok(("Neovim %d.%d.%d"):format(version.major, version.minor, version.patch))
  else
    health.error(
      ("Neovim %d.%d.%d is too old; wrfm needs >= 0.11"):format(
        version.major,
        version.minor,
        version.patch
      )
    )
  end

  -- 2. Render smoke test through the full in-memory pipeline.
  local ok_render, render_err = pcall(function()
    local parser = require("wrfm.parser")
    local renderer = require("wrfm.renderer")
    local data = parser.parse(CUBE)
    local lines = renderer.render_frame(data, {
      pitch = math.rad(30),
      yaw = math.rad(45),
      dist = renderer.fit_distance(data.vertices),
      width = 40,
      height = 12,
    })
    assert(#lines == 12 and #table.concat(lines) > 0, "empty frame")
    assert(contains_braille(table.concat(lines)), "no braille characters in frame")
  end)
  if ok_render then
    health.ok("render pipeline: inline cube rasterized to braille")
  else
    health.error("render smoke test failed: " .. tostring(render_err))
  end

  -- 3. Parser smoke test on minimal valid text.
  local ok_parse, parse_err = pcall(function()
    local parser = require("wrfm.parser")
    local data = parser.parse("wrfm 1\nvertices 1 edges 0\nv 0.5 -0.5 2\n")
    assert(#data.vertices == 1 and #data.edges == 0, "unexpected element counts")
  end)
  if ok_parse then
    health.ok(".wrfm parser: minimal model accepted")
  else
    health.error("parser smoke test failed: " .. tostring(parse_err))
  end

  -- 4. Timer machinery (drives auto-spin).
  local uv = vim.uv or vim.loop
  local ok_timer, timer_err = pcall(function()
    local timer = assert(uv.new_timer(), "uv.new_timer returned nil")
    timer:start(1, 0, function() end)
    timer:stop()
    timer:close()
  end)
  if ok_timer then
    health.ok("uv timers available (auto-spin)")
  else
    health.error("timer smoke test failed: " .. tostring(timer_err))
  end

  -- 5. Current configuration summary.
  local config = require("wrfm").config
  health.info(
    ("config: fps=%s default_pitch=%s default_fov=%s default_auto_spin=%s default_spin_speed=%s default_watch=%s highlight=%s"):format(
      tostring(config.fps),
      tostring(config.default_pitch),
      tostring(config.default_fov),
      tostring(config.default_auto_spin),
      tostring(config.default_spin_speed),
      tostring(config.default_watch),
      tostring(config.highlight)
    )
  )
  health.info(
    ("config: default_overflow=%s default_z_order=%s"):format(
      tostring(config.default_overflow),
      tostring(config.default_z_order)
    )
  )
  health.info(
    ("config: max_width=%s max_height=%s max_width_window_percentage=%s%% max_height_window_percentage=%s%%"):format(
      tostring(config.max_width),
      tostring(config.max_height),
      tostring(config.max_width_window_percentage),
      tostring(config.max_height_window_percentage)
    )
  )

  -- 6. Advisory: the wrfm CLI only matters for regenerating golden fixtures.
  if vim.fn.executable("wrfm") == 1 then
    health.ok("wrfm CLI found on PATH (golden fixtures can be regenerated with `mise run golden`)")
  else
    health.warn(
      "wrfm CLI not on PATH — only needed to regenerate golden fixtures, not to run this plugin"
    )
  end
end

return M
