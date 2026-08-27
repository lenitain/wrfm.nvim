-- Headless end-to-end flows: float lifecycle, auto-spin, setters, user-close,
-- bound-buffer mode, anchor-window mode, and the :Wrfm command surface.
local helpers = require("helpers")
local repo = helpers.repo_dir()
dofile(repo .. "/plugin/wrfm.lua")

local wrfm = require("wrfm")
local api = vim.api

local anvil = helpers.fixture_model("anvil-mini")
local cube = helpers.fixture_model("cube")
local mocks = helpers.mock_manager()

describe("e2e", function()
  before_each(function()
    helpers.prepare()
    mocks:reset()
  end)

  after_each(function()
    mocks:restore_all()
    helpers.restore_env()
  end)

  it("setup + float lifecycle", function()
    wrfm.setup({ default_spin_speed = 0.05, fps = 60 })
    assert.are.equal(0.05, wrfm.config.default_spin_speed, "setup overrides defaults")
    assert.are.equal(60, wrfm.config.fps, "setup overrides fps")

    local model = wrfm.from_file(anvil, { width = 40, height = 12 })
    model:render()

    assert.is_truthy(
      model.winid and api.nvim_win_is_valid(model.winid),
      "render opens a floating window"
    )
    local win_config = api.nvim_win_get_config(model.winid)
    assert.are.equal("editor", win_config.relative, "float is editor-relative")
    assert.are.equal(40, win_config.width, "float matches requested canvas width")
    assert.are.equal(12, win_config.height, "float matches requested canvas height")
    assert.are.equal(
      model.bufnr,
      api.nvim_win_get_buf(model.winid),
      "window shows the model buffer"
    )
    assert.are.equal(
      "nofile",
      api.nvim_get_option_value("buftype", { buf = model.bufnr }),
      "scratch buffer is nofile"
    )
    assert.is_false(
      api.nvim_get_option_value("modifiable", { buf = model.bufnr }),
      "scratch buffer is not modifiable"
    )
    assert.is_true(helpers.braille_cells(model.bufnr) > 100, "buffer holds a rendered frame")
    assert.is_truthy(win_config.col > 0 and win_config.row >= 0, "float is positioned on-grid")
    assert.are.equal(
      false,
      api.nvim_win_get_config(model.winid).focusable,
      "viewer floats are non-focusable decorations"
    )
    assert.is_truthy(
      api.nvim_get_current_win() ~= model.winid,
      "render leaves the user's window focused"
    )
    model:clear()
  end)

  it("auto-spin and setters", function()
    local model = wrfm.from_file(anvil, { width = 40, height = 12, auto_spin = false })
    model:render()
    assert.is_true(helpers.braille_cells(model.bufnr) > 0, "static render produced frames")

    local cells_a = helpers.braille_cells(model.bufnr)
    model:set_spin(true)
    assert.is_truthy(
      vim.wait(500, function()
        return helpers.braille_cells(model.bufnr) ~= cells_a
      end),
      "starting spin repaints the buffer"
    )

    model:set_spin(false)
    local frozen_yaw = model.yaw
    vim.wait(120)
    assert.is_true(math.abs(model.yaw - frozen_yaw) < 1e-9, "spin stopped or never started")

    model:set_pitch(70)
    assert.is.near(math.rad(70), model.pitch, 1e-9, "set_pitch stores radians")
    local pitch_frame = api.nvim_buf_get_lines(model.bufnr, 0, -1, false)
    model:set_distance(4)
    local far_frame = api.nvim_buf_get_lines(model.bufnr, 0, -1, false)
    local differs = false
    for i, line in ipairs(far_frame) do
      if line ~= (pitch_frame[i] or "") then
        differs = true
        break
      end
    end
    assert.is_true(differs, "set_distance changes the rendered framing")
    model:clear()
  end)

  it("spin timer advances yaw", function()
    local model = wrfm.from_file(anvil, { width = 30, height = 10, spin_speed = 0.3 })
    model:render()
    local yaw_before = model.yaw
    assert.is_truthy(
      vim.wait(400, function()
        return math.abs(model.yaw - yaw_before) > 0.01
      end),
      "auto-spin advances yaw via the timer"
    )

    model:set_spin(false)
    local frozen = model.yaw
    vim.wait(120)
    assert.is_true(math.abs(model.yaw - frozen) < 1e-9, "set_spin(false) stops the timer")
    assert.is_truthy(
      model.timer and not model.timer:is_active(),
      "timer handle stopped but kept for restart"
    )

    model:set_spin(true)
    assert.is_truthy(
      vim.wait(400, function()
        return math.abs(model.yaw - frozen) > 0.01
      end),
      "set_spin(true) restarts spinning"
    )
    model:clear()
  end)

  it("spin pauses while the host window is unfocused", function()
    local model = wrfm.from_file(anvil, { width = 30, height = 10, spin_speed = 0.3 })
    model:render()
    local host_win = api.nvim_get_current_win()
    assert.are.equal(host_win, model.host_win, "precondition: host is the current window")

    local yaw0 = model.yaw
    model:_tick()
    assert.is_true(math.abs(model.yaw - yaw0) > 1e-9, "focused model advances on tick")

    -- Focus a second window: the float model is now out of focus.
    vim.cmd("vsplit")
    assert.is_true(api.nvim_get_current_win() ~= host_win, "precondition: split took focus")
    local frame_before = api.nvim_buf_get_lines(model.bufnr, 0, -1, false)
    local yaw_hidden = model.yaw
    for _ = 1, 5 do
      model:_tick()
    end
    assert.is_true(math.abs(model.yaw - yaw_hidden) < 1e-9, "unfocused model does not advance yaw")
    local frame_after = api.nvim_buf_get_lines(model.bufnr, 0, -1, false)
    local unchanged = true
    for i, line in ipairs(frame_before) do
      if line ~= (frame_after[i] or "") then
        unchanged = false
        break
      end
    end
    assert.is_true(unchanged, "unfocused model skips the per-tick repaint")

    -- Focus returns to the host window: spin resumes.
    vim.cmd("wincmd p")
    assert.are.equal(host_win, api.nvim_get_current_win(), "precondition: focus back on host")
    local yaw_back = model.yaw
    model:_tick()
    assert.is_true(math.abs(model.yaw - yaw_back) > 1e-9, "refocused model advances again")
    model:clear()
  end)

  it("pause_spin_when_unfocused=false keeps background models spinning", function()
    local model = wrfm.from_file(anvil, {
      width = 30,
      height = 10,
      spin_speed = 0.3,
      pause_spin_when_unfocused = false,
    })
    model:render()
    local host_win = api.nvim_get_current_win()
    vim.cmd("vsplit")
    assert.is_true(api.nvim_get_current_win() ~= host_win, "precondition: split took focus")
    local yaw_hidden = model.yaw
    for _ = 1, 5 do
      model:_tick()
    end
    assert.is_true(
      math.abs(model.yaw - yaw_hidden) > 1e-9,
      "opt-out keeps advancing while unfocused"
    )
    model:clear()
  end)

  it("auto-spin turns the model around its own Y axis", function()
    local r = require("wrfm.renderer")
    local model = wrfm.from_file(cube, { width = 40, height = 12, auto_spin = false })
    model:render()
    local dist = model.dist_opt or model.fit_dist

    local function screen_of(v)
      local xs, ys = r.project({ v }, model.rot, dist, 48)
      return xs[1], ys[1]
    end

    local axis_x, axis_y = screen_of({ 0, 1, 0 })
    local off_x, off_y = screen_of({ 1, 0, 0 })
    for _ = 1, 7 do
      model:_tick()
    end
    local axis_x2, axis_y2 = screen_of({ 0, 1, 0 })
    assert.is.near(axis_x, axis_x2, 1e-9, "own-Y axis tip keeps its screen x under spin")
    assert.is.near(axis_y, axis_y2, 1e-9, "own-Y axis tip keeps its screen y under spin")

    local off_x2, off_y2 = screen_of({ 1, 0, 0 })
    assert.is_true(
      (off_x2 - off_x) ^ 2 + (off_y2 - off_y) ^ 2 > 1e-6,
      "off-axis points move under spin"
    )
    model:clear()
  end)

  it("borderless seamless float", function()
    local model =
      wrfm.from_file(cube, { width = 20, height = 6, auto_spin = false, border = false })
    model:render()
    local cfg = api.nvim_win_get_config(model.winid)
    assert.is_truthy(
      cfg.border == nil or cfg.border == "none",
      "border=false opens a frameless float"
    )
    assert.is_truthy(cfg.title == nil or cfg.title == "", "frameless float carries no title")
    local whl = api.nvim_get_option_value("winhighlight", { win = model.winid })
    assert.is_truthy(whl:find("NormalFloat:Normal", 1, true), "background merges into Normal")
    assert.is_false(model.border, "border flag stored on the model")

    local framed = wrfm.from_file(cube, { width = 20, height = 6, auto_spin = false })
    framed:render()
    assert.is_truthy(
      api.nvim_win_get_config(framed.winid).border ~= "none",
      "default float keeps its border"
    )
    framed:clear()
    model:clear()
  end)

  it("user closes the window", function()
    local model = wrfm.from_file(anvil, { width = 30, height = 10, spin_speed = 0.3 })
    model:render()
    api.nvim_win_close(model.winid, false)
    assert.is_truthy(
      vim.wait(400, function()
        return model.winid == nil
      end),
      "closing the window clears the model state on the next tick"
    )
    assert.is_nil(model.timer, "teardown stops the timer")
    assert.are.equal(0, #wrfm.get_models(), "user-close unregisters the model")
  end)

  it("bound-buffer mode", function()
    local host = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(host, 0, -1, false, { "original line" })
    local bound =
      wrfm.from_file(anvil, { buffer = host, width = 20, height = 6, auto_spin = false })
    bound:render()
    assert.are.equal(host, bound.bufnr, "bound mode draws into the given buffer")
    assert.is_nil(bound.winid, "bound mode opens no window")
    local has_art = false
    for _, line in ipairs(api.nvim_buf_get_lines(host, 0, -1, false)) do
      if line ~= "" then
        has_art = true
        break
      end
    end
    assert.is_true(has_art, "bound mode replaces buffer content with art")
    bound:clear()
    assert.are.equal(
      "original line",
      api.nvim_buf_get_lines(host, 0, -1, false)[1],
      "clear restores bound-buffer content"
    )
    assert.is_true(api.nvim_buf_is_valid(host), "foreign buffer survives clear")
  end)

  it("anchor-window mode", function()
    local anchor_model =
      wrfm.from_file(anvil, { width = 30, height = 10, window = 0, auto_spin = false })
    anchor_model:render()
    local anchored_config = api.nvim_win_get_config(anchor_model.winid)
    assert.are.equal("win", anchored_config.relative, "anchor option binds the float to a window")
    anchor_model:clear()
  end)

  it("moved float keeps its place through relayout", function()
    local lines_opt = vim.o.lines
    local model = wrfm.from_file(cube, { auto_spin = false })
    model:render()
    model:move(10, 5)

    vim.o.lines = lines_opt + 20
    api.nvim_exec_autocmds("VimResized", {})
    vim.wait(200)

    local cfg = api.nvim_win_get_config(model.winid)
    assert.are.equal(5, cfg.row, "relayout after move() preserves the chosen row")
    assert.are.equal(10, cfg.col, "relayout after move() preserves the chosen column")
    assert.are.equal("editor", cfg.relative, "moved float stays editor-relative")

    vim.o.lines = lines_opt
    model:clear()
  end)

  it("commands", function()
    vim.cmd(("Wrfm %s"):format(anvil))
    assert.is_truthy(
      wrfm.current and wrfm.current.winid and api.nvim_win_is_valid(wrfm.current.winid),
      ":Wrfm opens the viewer"
    )
    vim.cmd("WrfmClear")
    assert.is_nil(wrfm.current, ":WrfmClear closes the viewer")

    local failed = pcall(vim.cmd, "Wrfm /definitely/not/here.wrfm")
    assert.is_false(failed, ":Wrfm with a bad path raises instead of rendering")

    vim.cmd(("Wrfm %s"):format(cube))
    local file_viewer = wrfm.get_models()[1]
    vim.cmd(("Wrfm %s"):format(cube))
    assert.are.equal(1, #wrfm.get_models(), "two :Wrfm calls yield one idempotent viewer")
    assert.are.equal(file_viewer, wrfm.get_models()[1], "the reused viewer keeps its identity")

    wrfm.from_file(cube, { auto_spin = false })
    vim.cmd(("WrfmClear %s"):format(file_viewer.id))
    assert.are.equal(1, #wrfm.get_models(), ":WrfmClear <id> leaves the independent viewer open")
    assert.are_not.equal(file_viewer, wrfm.get_models()[1], "the right viewer survived")
    vim.cmd("WrfmClear")
  end)

  it("stale sweep clears dead contexts", function()
    local floater = wrfm.from_file(cube, { width = 20, height = 6, auto_spin = false })
    floater:render()
    api.nvim_win_close(floater.winid, false)
    vim.wait(100)
    assert.are.equal(0, #wrfm.get_models(), "user-closed float is swept from the registry")

    local host = api.nvim_get_current_win()
    local original_buf = api.nvim_win_get_buf(host)
    local anchored =
      wrfm.from_file(cube, { window = host, width = 20, height = 6, auto_spin = false })
    anchored:render()
    local other = api.nvim_create_buf(true, false)
    api.nvim_win_set_buf(host, other)
    api.nvim_exec_autocmds("BufEnter", {})
    vim.wait(100)
    assert.are.equal(
      0,
      #wrfm.get_models(),
      "anchored overlay dies when its host shows other content"
    )
    api.nvim_win_set_buf(host, original_buf)

    local bufnr = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(bufnr, cube)
    local inline = wrfm.attach(bufnr, { path = cube, width = 20, height = 6, watch = false })
    assert.are.equal(1, #wrfm.get_models(), "precondition: inline model live")
    api.nvim_buf_delete(bufnr, { force = true })
    api.nvim_exec_autocmds("BufEnter", {})
    vim.wait(100)
    assert.are.equal(0, #wrfm.get_models(), "deleted host buffer sweeps the inline preview")

    local kept_float = wrfm.from_file(anvil, { width = 20, height = 6, auto_spin = false })
    kept_float:render()
    local bound_host = api.nvim_create_buf(true, false)
    local kept_bound =
      wrfm.from_file(anvil, { buffer = bound_host, width = 20, height = 6, auto_spin = false })
    kept_bound:render()
    local hidden = wrfm.from_file(anvil, { width = 20, height = 6, auto_spin = false })
    hidden:render()
    hidden:hide()
    api.nvim_exec_autocmds("TabEnter", {})
    api.nvim_exec_autocmds("BufEnter", {})
    vim.wait(150)
    assert.are.equal(3, #wrfm.get_models(), "valid windows/buffers are never swept")
    assert.is_nil(hidden.winid, "hidden model stays hidden and registered")

    api.nvim_buf_delete(bound_host, { force = true })
    api.nvim_exec_autocmds("BufEnter", {})
    vim.wait(100)
    assert.are.equal(2, #wrfm.get_models(), "deleted bound host sweeps the bound model")

    kept_float:clear()
    hidden:clear()
  end)

  it("x/y offsets place the float", function()
    local columns, lines, cmdheight = vim.o.columns, vim.o.lines, vim.o.cmdheight
    local w, h = 20, 6
    local center_col = math.floor((columns - w) / 2)
    local center_row = math.floor((lines - cmdheight - h) / 2)

    local model = wrfm.from_file(cube, { width = w, height = h, x = 10, y = 5, auto_spin = false })
    model:render()
    local cfg = api.nvim_win_get_config(model.winid)
    assert.are.equal(center_col + 10, cfg.col, "creation x offsets the centered column")
    assert.are.equal(center_row + 5, cfg.row, "creation y offsets the centered row")

    model:move(50, 50)
    model:render({ x = -4 })
    cfg = api.nvim_win_get_config(model.winid)
    assert.are.equal(center_col - 4, cfg.col, "geometry x re-centers then offsets")
    assert.are.equal(center_row + 5, cfg.row, "geometry y is left alone when nil")
    assert.are.equal("editor", cfg.relative, "offset application keeps editor-relative placement")
    assert.is_nil(model._moved, "applying offsets clears the manual-move marker")

    model:move(3, 7)
    cfg = api.nvim_win_get_config(model.winid)
    assert.are.equal(3, cfg.col, "move() keeps its absolute semantics")
    assert.are.equal(7, cfg.row, "move() keeps its absolute semantics")

    local clamped = wrfm.from_file(cube, { width = w, height = h, x = -10000, auto_spin = false })
    clamped:render()
    assert.are.equal(0, api.nvim_win_get_config(clamped.winid).col, "offsets clamp at column 0")
    clamped:clear()

    local anchor = api.nvim_get_current_win()
    local aw = api.nvim_win_get_width(anchor)
    local ah = api.nvim_win_get_height(anchor)
    local attached = wrfm.from_file(
      cube,
      { window = anchor, width = w, height = h, x = 2, y = 1, auto_spin = false }
    )
    attached:render()
    local acfg = api.nvim_win_get_config(attached.winid)
    assert.are.equal(
      math.floor((aw - w) / 2) + 2,
      acfg.col,
      "anchored x offsets around the anchor center"
    )
    assert.are.equal(
      math.floor((ah - h) / 2) + 1,
      acfg.row,
      "anchored y offsets around the anchor center"
    )
    attached:clear()
    model:clear()
  end)

  it("size caps clamp derived and explicit sizes", function()
    local saved = {
      max_width = wrfm.config.max_width,
      max_height = wrfm.config.max_height,
      max_w_pct = wrfm.config.max_width_window_percentage,
      max_h_pct = wrfm.config.max_height_window_percentage,
    }

    wrfm.setup({ max_width = 30, max_height = 5 })
    local derived = wrfm.from_file(cube, { auto_spin = false })
    derived:render()
    assert.is_true(derived.width <= 30, "absolute cap bounds the derived width")
    assert.is_true(derived.height <= 5, "absolute cap bounds the derived height")

    local explicit = wrfm.from_file(cube, { width = 50, height = 12, auto_spin = false })
    explicit:render()
    assert.are.equal(50, explicit.width, "explicit width bypasses absolute cap")
    assert.are.equal(12, explicit.height, "explicit height bypasses absolute cap")

    wrfm.config.max_width = saved.max_width
    wrfm.config.max_height = saved.max_height
    local host = api.nvim_get_current_win()
    local ww = api.nvim_win_get_width(host)
    local wide = wrfm.from_file(cube, { max_width_window_percentage = 100, auto_spin = false })
    wide:render()
    assert.are.equal(
      math.min(ww, vim.o.columns - 2),
      wide.width,
      "per-model percentage overrides the global one"
    )

    local free =
      wrfm.from_file(cube, { width = 200, height = 100, ignore_max_size = true, auto_spin = false })
    free:render()
    assert.are.equal(
      math.min(200, vim.o.columns - 2),
      free.width,
      "ignore_max_size keeps explicit width"
    )
    assert.are.equal(
      math.min(100, vim.o.lines - vim.o.cmdheight - 2),
      free.height,
      "terminal bounds still apply under ignore_max_size"
    )

    wrfm.config.max_width = saved.max_width
    wrfm.config.max_height = saved.max_height
    wrfm.config.max_width_window_percentage = saved.max_w_pct
    wrfm.config.max_height_window_percentage = saved.max_h_pct

    local plain = wrfm.from_file(cube, { auto_spin = false })
    plain:render()
    local base_w = api.nvim_win_get_width(api.nvim_get_current_win())
    local base_h = api.nvim_win_get_height(api.nvim_get_current_win())
    assert.are.equal(
      math.min(math.floor(base_w * 80 / 100), vim.o.columns - 2),
      plain.width,
      "default width stays at 80% of the window"
    )
    assert.are.equal(
      math.min(math.floor(base_h * 60 / 100), vim.o.lines - vim.o.cmdheight - 2),
      plain.height,
      "default height stays at 60% of the window"
    )
    plain:clear()

    wrfm.config.max_width = saved.max_width
    wrfm.config.max_height = saved.max_height
    wrfm.config.max_width_window_percentage = saved.max_w_pct
    wrfm.config.max_height_window_percentage = saved.max_h_pct
  end)

  it("relayout on VimResized", function()
    local lines_opt = vim.o.lines
    local host = api.nvim_get_current_win()
    local host_h = api.nvim_win_get_height(host)

    local derived = wrfm.from_file(cube, { auto_spin = false })
    derived:render()
    local explicit = wrfm.from_file(cube, { width = 20, height = 6, auto_spin = false })
    explicit:render()
    local old_height = derived.height

    vim.o.lines = lines_opt + 30
    api.nvim_win_set_height(host, host_h + 25)
    api.nvim_exec_autocmds("VimResized", {})
    vim.wait(300)

    local dcfg = api.nvim_win_get_config(derived.winid)
    assert.is_true(
      derived.height > old_height,
      ("derived model recomputed taller (%d -> %d)"):format(old_height, derived.height)
    )
    assert.are.equal(derived.height, dcfg.height, "float config height follows the new canvas size")
    assert.are.equal(derived.width, dcfg.width, "float config width stays in sync with the canvas")
    assert.are.equal(
      derived.height,
      #api.nvim_buf_get_lines(derived.bufnr, 0, -1, false),
      "buffer row count matches the new canvas height"
    )

    local ecfg = api.nvim_win_get_config(explicit.winid)
    assert.are.equal(20, ecfg.width, "explicit-width model keeps its size")
    assert.are.equal(6, ecfg.height, "explicit-height model keeps its size")

    api.nvim_win_set_height(host, host_h)
    vim.o.lines = lines_opt
    api.nvim_exec_autocmds("VimResized", {})
    vim.wait(100)
    derived:clear()
    explicit:clear()
  end)

  it("relayout on WinResized (anchored)", function()
    local anchor = api.nvim_get_current_win()
    local anchor_w = api.nvim_win_get_width(anchor)

    local model = wrfm.from_file(cube, { window = anchor, auto_spin = false })
    model:render()

    api.nvim_win_set_width(anchor, anchor_w + 25)
    api.nvim_exec_autocmds("WinResized", { data = { windows = { anchor } } })
    assert.is_truthy(
      vim.wait(300, function()
        return model.width ~= nil and model.width >= 1
      end),
      "anchored relayout ran"
    )

    local cfg = api.nvim_win_get_config(model.winid)
    assert.are.equal("win", cfg.relative, "float stays anchored after relayout")
    assert.are.equal(model.width, cfg.width, "anchored float resized with its anchor window")

    model:clear()
    api.nvim_win_set_width(anchor, anchor_w)
  end)

  it("hot reload picks up new geometry", function()
    local path = vim.fn.tempname() .. ".wrfm"
    helpers.write_file(
      path,
      [[
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
    )
    local model = wrfm.from_file(path, { width = 40, height = 12, auto_spin = false })
    model:render()
    model.yaw = 0.5

    helpers.write_file(
      path,
      [[
wrfm 1
vertices 10 edges 14
v -1 -1 -1
v 1 -1 -1
v 1 1 -1
v -1 1 -1
v -1 -1 1
v 1 -1 1
v 1 1 1
v -1 1 1
v 0 2 0
v 0 -2 0
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
e 8 4
e 9 0
]]
    )
    assert.is_truthy(
      vim.wait(1200, function()
        return #model.vertices == 10
      end),
      "appended vertices appear after the file changes"
    )
    assert.are.equal(14, #model.edges, "edges swapped too")
    assert.is.near(0.5, model.yaw, 1e-9, "yaw survives the reload")

    model:clear()
    assert.is_nil(model.watcher, "clear stops the watcher")
    os.remove(path)
  end)

  it("hot reload tolerates garbage and self-heals", function()
    local path = vim.fn.tempname() .. ".wrfm"
    helpers.write_file(
      path,
      "wrfm 1\nvertices 4 edges 6\nv 1 1 1\nv 1 -1 -1\nv -1 1 -1\nv -1 -1 1\ne 0 1\ne 0 2\ne 0 3\ne 1 2\ne 1 3\ne 2 3\n"
    )
    local model = wrfm.from_file(path, { width = 24, height = 8, auto_spin = false })
    model:render()
    assert.are.equal(4, #model.vertices, "initial tetra loaded")

    mocks:stub(vim, "notify_once", function() end)
    helpers.write_file(path, "this is not a wrfm file at all\n")
    vim.wait(700)

    assert.are.equal(4, #model.vertices, "invalid content keeps the last good frame")

    helpers.write_file(path, "wrfm 1\nvertices 2 edges 1\nv 0 0 0\nv 5 0 0\ne 0 1\n")
    local healed = vim.wait(1200, function()
      return #model.vertices == 2
    end)
    assert.is_truthy(healed, "valid content heals the viewer automatically")

    os.remove(path)
    vim.wait(700)
    assert.are.equal(2, #model.vertices, "deleted file keeps the last frame")
    assert.is_nil(model.watcher, "vanished file stops the watcher")

    model:clear()
  end)

  it("watch=false stays static", function()
    local path = vim.fn.tempname() .. ".wrfm"
    helpers.write_file(path, "wrfm 1\nvertices 2 edges 1\nv 0 0 0\nv 1 0 0\ne 0 1\n")
    local model = wrfm.from_file(path, { width = 20, height = 6, watch = false, auto_spin = false })
    model:render()
    assert.is_nil(model.watch_started, "no watcher started when watch=false")

    helpers.write_file(
      path,
      "wrfm 1\nvertices 3 edges 3\nv 0 0 0\nv 1 0 0\nv 0 1 0\ne 0 1\ne 1 2\ne 2 0\n"
    )
    vim.wait(700)
    assert.are.equal(2, #model.vertices, "file changes are ignored with watch=false")

    model:clear()
    os.remove(path)
  end)

  it("watcher survives hide, dies with clear (50x)", function()
    local path = vim.fn.tempname() .. ".wrfm"
    helpers.write_file(path, "wrfm 1\nvertices 2 edges 1\nv 0 0 0\nv 1 0 0\ne 0 1\n")

    for _ = 1, 50 do
      local m = wrfm.from_file(path, { width = 10, height = 4, auto_spin = false })
      m:render()
      m:clear()
    end
    assert.are.equal(0, #wrfm.get_models(), "registry empty after churn")
    assert.is_nil(wrfm.current, "current cursor empty after churn")

    local model = wrfm.from_file(path, { width = 10, height = 4, auto_spin = false })
    model:render()
    assert.is_truthy(model.watch_started, "watcher running before hide")
    wrfm.disable()
    assert.is_truthy(model.watch_started, "hide keeps the watcher alive")
    wrfm.enable()
    assert.is_truthy(model.winid and api.nvim_win_is_valid(model.winid), "enable rebuilds the view")
    model:clear()
    assert.is_nil(model.watcher, "clear tears the watcher down")
    os.remove(path)
  end)

  it("reload while disabled lands on enable", function()
    local path = vim.fn.tempname() .. ".wrfm"
    helpers.write_file(path, "wrfm 1\nvertices 2 edges 1\nv 0 0 0\nv 1 0 0\ne 0 1\n")
    local model = wrfm.from_file(path, { width = 16, height = 6, auto_spin = false })
    model:render()

    wrfm.disable()
    helpers.write_file(
      path,
      "wrfm 1\nvertices 4 edges 6\nv 1 1 1\nv 1 -1 -1\nv -1 1 -1\nv -1 -1 1\ne 0 1\ne 0 2\ne 0 3\ne 1 2\ne 1 3\ne 2 3\n"
    )
    local reloaded = vim.wait(1500, function()
      return #model.vertices == 4
    end)
    assert.is_truthy(reloaded, "hidden model still maintains geometry from file events")

    wrfm.enable()
    assert.is_truthy(
      model.winid and api.nvim_win_is_valid(model.winid),
      "enable presents the new geometry"
    )
    assert.are.equal(4, #model.vertices, "enabled viewer shows reloaded vertex count")
    model:clear()
    os.remove(path)
  end)

  it("FocusLost pauses spin, FocusGained resumes", function()
    wrfm.enabled = true
    local model = wrfm.from_file(anvil, { width = 24, height = 8 })
    model:render()
    assert.is_truthy(model.timer and model.timer:is_active(), "precondition: spin timer running")

    api.nvim_exec_autocmds("FocusLost", {})
    assert.is_truthy(model.timer and not model.timer:is_active(), "FocusLost stops the spin timer")
    assert.is_true(model._focus_stopped, "the pause is marked for resumption")

    api.nvim_exec_autocmds("FocusGained", {})
    assert.is_truthy(model.timer and model.timer:is_active(), "FocusGained restarts the spin timer")
    assert.is_nil(model._focus_stopped, "the marker is cleared on resume")
    model:clear()
  end)

  it("VimSuspend/VimResume mirror the focus handling", function()
    wrfm.enabled = true
    local model = wrfm.from_file(anvil, { width = 24, height = 8 })
    model:render()

    api.nvim_exec_autocmds("VimSuspend", {})
    assert.is_truthy(model.timer and not model.timer:is_active(), "VimSuspend stops the spin timer")

    api.nvim_exec_autocmds("VimResume", {})
    assert.is_truthy(model.timer and model.timer:is_active(), "VimResume restarts the spin timer")
    assert.is_nil(model._suspend_stopped, "suspend marker cleared independently of focus marker")
    model:clear()
  end)

  it("focus events never start a stopped or manual spin", function()
    wrfm.enabled = true
    local static = wrfm.from_file(anvil, { width = 20, height = 6, auto_spin = false })
    static:render()
    api.nvim_exec_autocmds("FocusLost", {})
    api.nvim_exec_autocmds("FocusGained", {})
    assert.is_nil(static.timer, "non-spinning models gain no timer from resume")

    local manual = wrfm.from_file(anvil, { width = 20, height = 6, auto_spin = true })
    manual:render()
    manual:set_spin(false)
    api.nvim_exec_autocmds("FocusLost", {})
    api.nvim_exec_autocmds("FocusGained", {})
    assert.is_truthy(
      manual.timer == nil or not manual.timer:is_active(),
      "set_spin(false) survives focus roundtrips"
    )
    manual:clear()
    static:clear()
  end)

  it("relayout repaints once per event burst", function()
    wrfm.enabled = true
    local model = wrfm.from_file(cube, { auto_spin = false, watch = false })
    model:render()

    local paints = 0
    local real_paint = model._paint
    ---@diagnostic disable-next-line: duplicate-set-field
    model._paint = function(self)
      paints = paints + 1
      real_paint(self)
    end

    model:_relayout()
    model:_relayout()
    vim.wait(100)

    assert.are.equal(1, paints, "burst of two relayouts paints exactly one frame")
    assert.are.equal(
      model.height,
      #api.nvim_buf_get_lines(model.bufnr, 0, -1, false),
      "coalesced paint leaves the buffer consistent"
    )
    model:clear()
  end)

  it("schedule_paint coalesces and resets", function()
    wrfm.enabled = true
    local model = wrfm.from_file(cube, { auto_spin = false, watch = false })
    model:render()

    assert.is_nil(model._paint_pending, "no paint pending before first call")
    model:_schedule_paint()
    assert.is_true(model._paint_pending, "flag set after first schedule_paint")
    model:_schedule_paint()
    model:_schedule_paint()
    assert.is_true(model._paint_pending, "redundant calls keep flag true")

    vim.wait(100)
    assert.is_false(model._paint_pending, "flag cleared after scheduled callback fires")

    model:_schedule_paint()
    assert.is_true(model._paint_pending, "second burst re-arms the flag")
    vim.wait(100)
    assert.is_false(model._paint_pending, "second burst also resolves")

    model:clear()
  end)
end)
