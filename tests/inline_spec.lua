-- Inline preview tests: extmark lifecycle, spin updates, cleanup.
local wrfm = require("wrfm")
local helpers = require("helpers")

local anvil = helpers.fixture_model("anvil-mini")
local cube = helpers.fixture_model("cube")
local mocks = helpers.mock_manager()

local function arm_cursor_follow(overrides)
  wrfm.setup({ integrations = { wrfm = overrides } })
  wrfm._ensure_integration_hooks()
  return function()
    wrfm.setup({
      integrations = { wrfm = { only_render_at_cursor = false, cursor_mode = "popup" } },
    })
    wrfm._ensure_integration_hooks()
  end
end

local function extmark_row(bufnr, model)
  local marks =
    vim.api.nvim_buf_get_extmark_by_id(bufnr, wrfm.inline_ns, model.inline_extmark_id, {})
  return marks[1]
end

describe("inline", function()
  before_each(function()
    wrfm.clear()
    mocks:reset()
  end)

  after_each(function()
    mocks:restore_all()
    wrfm.clear()
  end)

  it("extmark lifecycle", function()
    local bufnr = helpers.load_buf(anvil)
    local model = wrfm.from_file(anvil, {
      buffer = bufnr,
      width = 40,
      height = 12,
      auto_spin = false,
      watch = false,
    })
    model.inline = true
    model.inline_bufnr = bufnr
    model.inline_ns = wrfm.inline_ns
    model:render()

    assert.is_truthy(model.inline_extmark_id, "extmark created after render")
    local marks = vim.api.nvim_buf_get_extmark_by_id(
      bufnr,
      wrfm.inline_ns,
      model.inline_extmark_id,
      { details = true }
    )
    assert.is_true(#marks > 0, "extmark exists in buffer")
    local details = marks[3]
    assert.is_truthy(details and details.virt_lines, "extmark has virt_lines")
    assert.is_true(#details.virt_lines >= 10, "virt_lines height >= 10 rows")

    assert.are.equal(0, marks[1], "extmark anchored at line 0")

    local saved_id = model.inline_extmark_id
    model:clear()
    assert.is_nil(model.inline_extmark_id, "inline_extmark_id cleared")
    local after = vim.api.nvim_buf_get_extmark_by_id(bufnr, wrfm.inline_ns, saved_id, {})
    assert.are.equal(0, #after, "extmark deleted from buffer")

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("spin updates extmark content", function()
    local bufnr = helpers.load_buf(cube)
    local model = wrfm.from_file(cube, {
      buffer = bufnr,
      width = 30,
      height = 8,
      auto_spin = false,
      spin_speed = 0.1,
      watch = false,
    })
    model.inline = true
    model.inline_bufnr = bufnr
    model.inline_ns = wrfm.inline_ns
    local source_line = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1]
    model:render()

    local function virt_snapshot()
      local marks = vim.api.nvim_buf_get_extmark_by_id(
        bufnr,
        wrfm.inline_ns,
        model.inline_extmark_id,
        { details = true }
      )
      return marks[3].virt_lines
    end

    local id_before = model.inline_extmark_id
    local before = virt_snapshot()

    model:_tick()

    assert.are.equal(id_before, model.inline_extmark_id, "extmark id stable across ticks")
    assert.are_not.equal(before, virt_snapshot(), "tick repaints the frame")
    assert.are.equal(
      source_line,
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1],
      "tick never overwrites host buffer content"
    )

    model:clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("attach / detach", function()
    local bufnr = helpers.load_buf(cube)
    vim.api.nvim_buf_set_name(bufnr, cube)

    local model =
      wrfm.attach(bufnr, { path = cube, width = 30, height = 8, auto_spin = false, watch = false })
    assert.is_truthy(model.inline, "attach sets inline flag")
    assert.are.equal(bufnr, model.inline_bufnr, "attach binds to given buffer")
    assert.is_truthy(model.inline_extmark_id, "attach creates extmark")

    local marks = vim.api.nvim_buf_get_extmark_by_id(
      bufnr,
      wrfm.inline_ns,
      model.inline_extmark_id,
      { details = true }
    )
    assert.is_truthy(#marks > 0 and marks[3].virt_lines, "extmark has virt_lines after attach")

    assert.are.equal(
      1,
      #wrfm.get_models({ buffer = bufnr }),
      "get_models finds inline model by buffer"
    )

    wrfm.detach(bufnr)
    assert.are.equal(0, #wrfm.get_models({ buffer = bufnr }), "detach removes model from registry")

    local after =
      vim.api.nvim_buf_get_extmark_by_id(bufnr, wrfm.inline_ns, model.inline_extmark_id or -1, {})
    assert.are.equal(0, #after, "extmark gone after detach")

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("popup lifecycle", function()
    local bufnr = helpers.load_buf(cube)
    vim.api.nvim_buf_set_name(bufnr, cube)

    local model = wrfm.attach(bufnr, {
      path = cube,
      width = 30,
      height = 8,
      auto_spin = false,
      watch = false,
      only_render_at_cursor = true,
      cursor_mode = "popup",
    })
    assert.is_truthy(model.only_render_at_cursor, "popup model has only_render_at_cursor set")
    assert.are.equal("popup", model.cursor_mode, "cursor_mode is popup")
    assert.is_truthy(
      model.popup_winid and vim.api.nvim_win_is_valid(model.popup_winid),
      "popup window opened"
    )
    local popup_buf = vim.api.nvim_win_get_buf(model.popup_winid)
    assert.is_true(
      #vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false) > 0,
      "popup buffer has content"
    )

    model:_close_popup()
    assert.is_nil(model.popup_winid, "close_popup nils the handle")

    wrfm.detach(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("insert mode hide / restore", function()
    local bufnr = helpers.load_buf(cube)
    vim.api.nvim_buf_set_name(bufnr, cube)

    local model =
      wrfm.attach(bufnr, { path = cube, width = 30, height = 8, auto_spin = false, watch = false })
    assert.is_truthy(model.inline_extmark_id, "precondition: extmark exists")
    local extmark_id = model.inline_extmark_id

    model:_clear_inline()
    assert.is_nil(model.inline_extmark_id, "clear_inline removes extmark id")
    local gone = vim.api.nvim_buf_get_extmark_by_id(bufnr, wrfm.inline_ns, extmark_id, {})
    assert.are.equal(0, #gone, "extmark gone after clear_inline")

    model:_render_inline()
    assert.is_truthy(model.inline_extmark_id, "render_inline restores extmark")
    local restored = vim.api.nvim_buf_get_extmark_by_id(
      bufnr,
      wrfm.inline_ns,
      model.inline_extmark_id,
      { details = true }
    )
    assert.is_truthy(#restored > 0 and restored[3].virt_lines, "restored extmark has virt_lines")

    wrfm.detach(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("commands", function()
    dofile(helpers.repo_dir() .. "/plugin/wrfm.lua")
    local bufnr = helpers.load_buf(cube)
    vim.api.nvim_buf_set_name(bufnr, cube)
    vim.api.nvim_set_current_buf(bufnr)

    vim.cmd("WrfmHere")
    local models = wrfm.get_models({ buffer = bufnr })
    assert.are.equal(1, #models, ":WrfmHere creates one inline model")
    assert.is_truthy(models[1].inline, "model is inline")
    assert.is_truthy(models[1].inline_extmark_id, "extmark created by :WrfmHere")

    vim.cmd("WrfmHere")
    assert.are.equal(1, #wrfm.get_models({ buffer = bufnr }), ":WrfmHere twice stays idempotent")

    vim.cmd("WrfmDetach")
    assert.are.equal(0, #wrfm.get_models({ buffer = bufnr }), ":WrfmDetach removes inline model")

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("cursor follow re-anchors the extmark (inline mode)", function()
    local restore = arm_cursor_follow({ only_render_at_cursor = true, cursor_mode = "inline" })
    local original_buf = vim.api.nvim_get_current_buf()

    local bufnr = helpers.load_buf(cube)
    vim.api.nvim_buf_set_name(bufnr, cube)
    vim.bo[bufnr].filetype = "wrfm"
    local models = wrfm.get_models({ buffer = bufnr })
    assert.are.equal(1, #models, "auto-attach created the cursor-only preview")
    local model = models[1]
    if not model then
      restore()
      return
    end

    vim.api.nvim_set_current_buf(bufnr)
    assert.are.equal(0, extmark_row(bufnr, model), "preview starts at the first cursor line")

    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { pattern = "wrfm" })
    assert.are.equal(
      9,
      extmark_row(bufnr, model),
      "cursor move re-anchors the extmark (0-based row 9)"
    )

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_exec_autocmds("CursorMovedI", { pattern = "wrfm" })
    assert.are.equal(2, extmark_row(bufnr, model), "insert-mode cursor moves are followed too")

    wrfm.clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.api.nvim_set_current_buf(original_buf)
    restore()
  end)

  it("cursor follow reopens the popup (popup mode)", function()
    local restore = arm_cursor_follow({ only_render_at_cursor = true })
    local original_buf = vim.api.nvim_get_current_buf()

    local bufnr = helpers.load_buf(cube)
    vim.api.nvim_buf_set_name(bufnr, cube)
    vim.bo[bufnr].filetype = "wrfm"
    local model = wrfm.get_models({ buffer = bufnr })[1]
    if not model then
      restore()
      return
    end

    vim.api.nvim_set_current_buf(bufnr)
    assert.is_truthy(
      model.popup_winid and vim.api.nvim_win_is_valid(model.popup_winid),
      "precondition: popup open at the initial cursor"
    )

    vim.api.nvim_win_set_cursor(0, { 12, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { pattern = "wrfm" })

    assert.is_truthy(model.popup_winid, "popup survives cursor movement under follow mode")
    if model.popup_winid then
      assert.is_truthy(
        vim.api.nvim_win_is_valid(model.popup_winid),
        "popup reopened at the new cursor"
      )
      local rel = vim.api.nvim_win_get_config(model.popup_winid).relative
      assert.is_truthy(rel == "cursor" or rel == "win", "popup stays anchored at the cursor")
    end

    wrfm.clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.api.nvim_set_current_buf(original_buf)
    restore()
  end)

  it("cursor follow spares non-cursor models", function()
    local restore = arm_cursor_follow({ only_render_at_cursor = true, cursor_mode = "inline" })
    local original_buf = vim.api.nvim_get_current_buf()

    local bufnr = helpers.load_buf(cube)
    vim.api.nvim_buf_set_name(bufnr, cube)
    local model = wrfm.attach(bufnr, { path = cube, only_render_at_cursor = false, watch = false })
    assert.is_false(model.only_render_at_cursor, "explicit opt-out wins over integration config")

    vim.api.nvim_set_current_buf(bufnr)
    local row_before = extmark_row(bufnr, model)
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { pattern = "wrfm" })
    vim.wait(50)

    assert.are.equal(row_before, extmark_row(bufnr, model), "extmark stays put for normal previews")
    assert.is_nil(model.popup_winid, "no popup appears for normal previews")

    wrfm.clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.api.nvim_set_current_buf(original_buf)
    restore()
  end)

  it("unsaved edits live-preview via the buffer channel", function()
    local path = vim.fn.tempname() .. ".wrfm"
    helpers.write_file(path, "wrfm 1\nvertices 2 edges 1\nv 0 0 0\nv 1 0 0\ne 0 1\n")
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "wrfm 1",
      "vertices 2 edges 1",
      "v 0 0 0",
      "v 1 0 0",
      "e 0 1",
      "",
    })
    vim.bo[bufnr].modified = false
    local model = wrfm.attach(bufnr, { path = path, width = 20, height = 6, auto_spin = false })
    assert.is_truthy(model.buf_watching, "buffer watcher armed for inline previews")
    assert.is_truthy(model.watch_started, "disk watcher runs alongside the buffer channel")
    assert.are.equal(2, #model.vertices, "initial geometry loaded")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "wrfm 1",
      "vertices 10 edges 14",
      "v -1 -1 -1",
      "v 1 -1 -1",
      "v 1 1 -1",
      "v -1 1 -1",
      "v -1 -1 1",
      "v 1 -1 1",
      "v 1 1 1",
      "v -1 1 1",
      "v 0 2 0",
      "v 0 -2 0",
      "e 0 1",
      "e 1 2",
      "e 2 3",
      "e 3 0",
      "e 4 5",
      "e 5 6",
      "e 6 7",
      "e 7 4",
      "e 0 4",
      "e 1 5",
      "e 2 6",
      "e 3 7",
      "e 8 4",
      "e 9 0",
      "",
    })
    assert.is_truthy(
      vim.wait(800, function()
        return #model.vertices == 10
      end),
      "unsaved buffer edits swap the geometry live"
    )

    mocks:stub(vim, "notify_once", function() end)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "total garbage", "" })
    vim.wait(600)
    assert.are.equal(10, #model.vertices, "unparseable edit keeps the last good frame")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "wrfm 1",
      "vertices 4 edges 6",
      "v 1 1 1",
      "v 1 -1 -1",
      "v -1 1 -1",
      "v -1 -1 1",
      "e 0 1",
      "e 0 2",
      "e 0 3",
      "e 1 2",
      "e 1 3",
      "e 2 3",
      "",
    })
    local healed = vim.wait(800, function()
      return #model.vertices == 4
    end)
    assert.is_truthy(healed, "a valid edit heals the preview automatically")

    vim.wait(300)
    local renders = 0
    local real_repaint = model._repaint
    ---@diagnostic disable-next-line: duplicate-set-field
    model._repaint = function(self)
      renders = renders + 1
      return real_repaint(self)
    end
    helpers.write_file(
      path,
      table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"
    )
    vim.wait(800)
    assert.are.equal(
      0,
      renders,
      "saving the shown content back does not repaint (dual-channel dedup)"
    )

    model:clear()
    assert.is_nil(model.buf_watching, "clear detaches the buffer watcher")
    os.remove(path)
  end)

  it("watch=false ignores buffer edits too", function()
    local path = vim.fn.tempname() .. ".wrfm"
    helpers.write_file(path, "wrfm 1\nvertices 2 edges 1\nv 0 0 0\nv 1 0 0\ne 0 1\n")
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "wrfm 1",
      "vertices 2 edges 1",
      "v 0 0 0",
      "v 1 0 0",
      "e 0 1",
      "",
    })
    local model =
      wrfm.attach(bufnr, { path = path, width = 20, height = 6, auto_spin = false, watch = false })
    assert.is_nil(model.buf_watching, "no buffer watcher when watch=false")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "garbage", "" })
    vim.wait(500)
    assert.are.equal(2, #model.vertices, "buffer edits are ignored like disk changes")

    model:clear()
    os.remove(path)
  end)

  it("virt_lines_above anchors above or below", function()
    local b1 = helpers.load_buf(anvil)
    local above = wrfm.from_file(anvil, {
      buffer = b1,
      width = 20,
      height = 6,
      auto_spin = false,
      watch = false,
    })
    above.inline = true
    above.inline_bufnr = b1
    above.inline_ns = wrfm.inline_ns
    above:render()
    local details = vim.api.nvim_buf_get_extmark_by_id(
      b1,
      wrfm.inline_ns,
      above.inline_extmark_id,
      { details = true }
    )[3]
    assert.is_true(details.virt_lines_above, "default anchors the preview above the line")

    local b2 = helpers.load_buf(anvil)
    local below = wrfm.from_file(anvil, {
      buffer = b2,
      width = 20,
      height = 6,
      auto_spin = false,
      watch = false,
      virt_lines_above = false,
    })
    below.inline = true
    below.inline_bufnr = b2
    below.inline_ns = wrfm.inline_ns
    below:render()
    local details_below = vim.api.nvim_buf_get_extmark_by_id(
      b2,
      wrfm.inline_ns,
      below.inline_extmark_id,
      { details = true }
    )[3]
    assert.is_false(details_below.virt_lines_above, "virt_lines_above=false anchors below the line")

    local b3 = helpers.load_buf(anvil)
    vim.api.nvim_buf_set_name(b3, anvil)
    local popup_model = wrfm.attach(
      b3,
      { path = anvil, only_render_at_cursor = true, watch = false, virt_lines_above = false }
    )
    assert.is_truthy(
      popup_model.popup_winid and vim.api.nvim_win_is_valid(popup_model.popup_winid),
      "popup rendering ignores virt_lines_above"
    )

    above:clear()
    below:clear()
    popup_model:clear()
    pcall(vim.api.nvim_buf_delete, b1, { force = true })
    pcall(vim.api.nvim_buf_delete, b2, { force = true })
    pcall(vim.api.nvim_buf_delete, b3, { force = true })
  end)
end)
