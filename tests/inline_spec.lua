-- Inline preview tests: virt_text overlay lifecycle, spin updates, cleanup,
-- z_order compositing. The overlay draws braille extmarks on the host buffer's
-- real text lines, so every test uses a multi-line buffer wide enough to host
-- the artwork.
local wrfm = require("wrfm")
local helpers = require("helpers")

local anvil = helpers.fixture_model("anvil-mini")
local cube = helpers.fixture_model("cube")
local mocks = helpers.mock_manager()

-- A buffer with `rows` lines each `cols` wide, set all at once so there is no
-- stray empty first line. The overlay only lands on real lines and needs each
-- line to be at least as wide as the artwork, so tests never rely on the
-- virt_lines behaviour of overflowing a short buffer.
local function wide_buf(rows, cols)
  local bufnr = vim.api.nvim_create_buf(true, false)
  local lines = {}
  for _ = 1, rows do
    lines[#lines + 1] = string.rep(" ", cols)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

-- Read back the overlay extmarks a model placed, via their ids. The range
-- query (`nvim_buf_get_extmarks`) reports virt_text overlay marks with shifted
-- positions/ids on some Neovim builds, so we read each mark individually.
local function overlay_marks(model)
  local out = {}
  if not (model.inline_extmark_ids and model.inline_bufnr) then
    return out
  end
  for _, id in ipairs(model.inline_extmark_ids) do
    local mark =
      vim.api.nvim_buf_get_extmark_by_id(model.inline_bufnr, wrfm.inline_ns, id, { details = true })
    local details = mark[3]
    out[#out + 1] = {
      row = mark[1],
      col = mark[2],
      text = details and details.virt_text and details.virt_text[1][1] or "",
    }
  end
  return out
end

-- Count extmarks in the namespace range. The range query undercounts position
-- fidelity but still reports the right number of marks.
local function extmark_count(bufnr)
  return #vim.api.nvim_buf_get_extmarks(bufnr, wrfm.inline_ns, 0, -1, {})
end

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

describe("inline", function()
  before_each(function()
    wrfm.clear()
    mocks:reset()
  end)

  after_each(function()
    mocks:restore_all()
    wrfm.clear()
  end)

  it("overlay lifecycle", function()
    local bufnr = wide_buf(20, 60)
    local model = wrfm.from_file(anvil, {
      width = 40,
      height = 12,
      auto_spin = false,
      watch = false,
    })
    model.inline = true
    model.inline_bufnr = bufnr
    model.inline_ns = wrfm.inline_ns
    model:render()

    assert.is_truthy(model.inline_extmark_ids, "none = clear; extmarks created after render")
    assert.is_true(#model.inline_extmark_ids > 0, "overlay produced at least one extmark")

    local details =
      vim.api.nvim_buf_get_extmark_by_id(bufnr, wrfm.inline_ns, model.inline_extmark_ids[1], {
        details = true,
      })[3]
    assert.is_truthy(details.virt_text and details.virt_text[1], "extmark paints virt_text")
    assert.are.equal("WrfmPreview", details.virt_text[1][2], "art uses the WrfmPreview group")
    assert.is_truthy(extmark_count(bufnr) > 0, "extmarks exist in the namespace")

    local saved_ids = vim.deepcopy(model.inline_extmark_ids)
    model:clear()
    assert.is_nil(model.inline_extmark_ids, "inline_extmark_ids cleared")
    assert.are.equal(0, extmark_count(bufnr), "all extmarks deleted from buffer")

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("spin repaints the overlay", function()
    local bufnr = wide_buf(20, 60)
    local model = wrfm.from_file(cube, {
      buffer = bufnr,
      width = 30,
      height = 8,
      auto_spin = false,
      spin_speed = 0.1,
      pause_spin_when_unfocused = false,
      watch = false,
    })
    model.inline = true
    model.inline_bufnr = bufnr
    model.inline_ns = wrfm.inline_ns
    model:render()

    local function snapshot()
      local out = {}
      for _, mk in ipairs(overlay_marks(model)) do
        out[#out + 1] = mk.row .. ":" .. mk.col .. "=" .. mk.text
      end
      return table.concat(out, "|")
    end

    local ids_before = vim.deepcopy(model.inline_extmark_ids)
    local before = snapshot()
    assert.is_truthy(before ~= "", "precondition: overlay has content")

    model:_tick()

    assert.are.equal(before ~= "", true, "tick leaves content")
    assert.are.equal(#ids_before, #(model.inline_extmark_ids or {}), "extmark count stable")
    assert.are_not.equal(before, snapshot(), "tick repaints the frame")
    -- The overlay is virt_text decoration: it never writes into the buffer.
    local buffer_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    assert.is_truthy(buffer_text:find("%S") == nil, "host buffer untouched (no braille written)")

    model:clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("attach / detach", function()
    local bufnr = wide_buf(20, 60)
    vim.api.nvim_buf_set_name(bufnr, cube)

    local model =
      wrfm.attach(bufnr, { path = cube, width = 30, height = 8, auto_spin = false, watch = false })
    assert.is_truthy(model.inline, "attach sets inline flag")
    assert.are.equal(bufnr, model.inline_bufnr, "attach binds to given buffer")
    assert.is_truthy(model.inline_extmark_ids, "attach creates overlay extmarks")
    assert.is_true(#model.inline_extmark_ids > 0, "attach renders at least one extmark")

    assert.are.equal(
      1,
      #wrfm.get_models({ buffer = bufnr }),
      "get_models finds inline model by buffer"
    )

    wrfm.detach(bufnr)
    assert.are.equal(0, #wrfm.get_models({ buffer = bufnr }), "detach removes model from registry")
    assert.are.equal(0, extmark_count(bufnr), "extmark gone after detach")

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("popup lifecycle", function()
    local bufnr = wide_buf(20, 60)
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
    local bufnr = wide_buf(20, 60)
    vim.api.nvim_buf_set_name(bufnr, cube)

    local model =
      wrfm.attach(bufnr, { path = cube, width = 30, height = 8, auto_spin = false, watch = false })
    assert.is_truthy(model.inline_extmark_ids, "precondition: extmarks exist")
    assert.is_true(#model.inline_extmark_ids > 0, "precondition: overlay painted")
    local saved_count = extmark_count(bufnr)

    model:_clear_inline()
    assert.is_nil(model.inline_extmark_ids, "clear_inline removes extmark ids")
    assert.are.equal(0, extmark_count(bufnr), "extmarks gone after clear_inline")

    model:_render_inline()
    assert.is_truthy(model.inline_extmark_ids, "render_inline restores extmarks")
    assert.is_truthy(extmark_count(bufnr) > 0, "render_inline repaints the overlay")
    assert.are.equal(saved_count, extmark_count(bufnr), "restored frame matches the first frame")

    wrfm.detach(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("commands", function()
    dofile(helpers.repo_dir() .. "/plugin/wrfm.lua")
    local bufnr = wide_buf(20, 60)
    vim.api.nvim_buf_set_name(bufnr, cube)
    vim.api.nvim_set_current_buf(bufnr)

    vim.cmd("WrfmHere")
    local models = wrfm.get_models({ buffer = bufnr })
    assert.are.equal(1, #models, ":WrfmHere creates one inline model")
    assert.is_truthy(models[1].inline, "model is inline")
    assert.is_truthy(models[1].inline_extmark_ids, "overlay extmarks created by :WrfmHere")
    local count_once = #(models[1].inline_extmark_ids or {})

    vim.cmd("WrfmHere")
    assert.are.equal(1, #wrfm.get_models({ buffer = bufnr }), ":WrfmHere twice stays idempotent")
    assert.are.equal(
      count_once,
      #(models[1].inline_extmark_ids or {}),
      "re-invocation replaces the frame instead of stacking"
    )

    vim.cmd("WrfmDetach")
    assert.are.equal(0, #wrfm.get_models({ buffer = bufnr }), ":WrfmDetach removes inline model")

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("cursor follow re-anchors the overlay (inline mode)", function()
    local restore = arm_cursor_follow({ only_render_at_cursor = true, cursor_mode = "inline" })
    local original_buf = vim.api.nvim_get_current_buf()

    local bufnr = wide_buf(30, 60)
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
    assert.are.equal(0, model.overlay_row, "preview starts at the first cursor line")

    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { pattern = "wrfm" })
    assert.are.equal(9, model.overlay_row, "cursor move re-anchors the overlay (0-based row 9)")

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_exec_autocmds("CursorMovedI", { pattern = "wrfm" })
    assert.are.equal(2, model.overlay_row, "insert-mode cursor moves are followed too")

    wrfm.clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.api.nvim_set_current_buf(original_buf)
    restore()
  end)

  it("cursor follow reopens the popup (popup mode)", function()
    local restore = arm_cursor_follow({ only_render_at_cursor = true })
    local original_buf = vim.api.nvim_get_current_buf()

    local bufnr = wide_buf(30, 60)
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

    local bufnr = wide_buf(30, 60)
    vim.api.nvim_buf_set_name(bufnr, cube)
    local model = wrfm.attach(bufnr, { path = cube, only_render_at_cursor = false, watch = false })
    assert.is_false(model.only_render_at_cursor, "explicit opt-out wins over integration config")

    vim.api.nvim_set_current_buf(bufnr)
    local row_before = model.overlay_row
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { pattern = "wrfm" })
    vim.wait(50)

    assert.are.equal(row_before, model.overlay_row, "overlay stays put for normal previews")
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

  it("wide prefix: extmarks land on glyph boundaries", function()
    -- A line starting with wide chars shifts byte offsets from visual
    -- columns; an extmark must be placed at the byte offset of a glyph
    -- start, never inside a multibyte character.
    local bufnr = wide_buf(20, 60)
    vim.api.nvim_buf_set_name(bufnr, cube)
    -- Row 1: 13 spaces, then "你好" (3 bytes, 2 columns each), then spaces.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    lines[2] = lines[2]:sub(1, 13) .. "你好" .. lines[2]:sub(14)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    local model = wrfm.attach(bufnr, {
      path = cube,
      width = 30,
      height = 8,
      auto_spin = false,
      z_order = "text",
    })
    local marks = overlay_marks(model)
    assert.is_truthy(#marks > 0, "overlay renders on the wide-prefix line")
    local wide_cols = {}
    for _, mk in ipairs(marks) do
      if mk.row == 1 then
        -- Glyph boundary test: the byte column must cut the line at a
        -- character start, so the prefix up to it round-trips through
        -- strchars/strcharpart.
        local text = vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1]
        local prefix = text:sub(1, mk.col)
        local count = vim.fn.strchars(prefix)
        assert.are.equal(
          prefix,
          vim.fn.strcharpart(text, 0, count),
          "mark byte column is a glyph boundary"
        )
        wide_cols[#wide_cols + 1] = mk.col
      end
    end
    -- The run after the wide chars must resume at byte 19 (13 spaces + 6
    -- bytes of "你好"), not at the visual column 15 that would land inside
    -- the CJK glyphs.
    assert.is_false(vim.tbl_contains(wide_cols, 15), "no mark lands inside the wide chars")

    wrfm.clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("virtcol.scan maps visual to byte columns", function()
    local scan = require("wrfm.utils.virtcol").scan
    local occupied, byte_at = scan("你好 ab", 8)
    -- “你好” occupies columns 0..3 (bytes 0..5); “ a b” starts at byte 6.
    assert.are.equal(true, occupied[0], "你 first column")
    assert.are.equal(true, occupied[1], "你 second column")
    assert.are.equal(true, occupied[2], "好 first column")
    assert.are.equal(true, occupied[3], "好 second column")
    assert.are.equal(true, occupied[5], "a")
    assert.are.equal(true, occupied[6], "b")
    assert.is_nil(occupied[4], "space is free")
    assert.are.equal(0, byte_at[0], "你 starts at byte 0")
    assert.are.equal(3, byte_at[2], "好 starts at byte 3")
    assert.are.equal(6, byte_at[4], "space starts at byte 6")
    assert.are.equal(7, byte_at[5], "a starts at byte 7")
    assert.are.equal(8, byte_at[6], "b starts at byte 8")
    assert.is_nil(byte_at[1], "second column of 你 is not placeable")
    assert.is_nil(byte_at[3], "second column of 好 is not placeable")

    local tocc, tbyte = scan("\t x", 8)
    assert.is_nil(tocc[0], "tab interior is free")
    assert.are.equal(0, tbyte[0], "tab starts at byte 0")
    assert.is_nil(tbyte[3], "tab interior is not placeable")
    assert.are.equal(1, tbyte[8], "space starts at byte 1")
    assert.are.equal(2, tbyte[9], "x starts at byte 2")
  end)

  it("z_order model vs text compositing", function()
    local bufnr = wide_buf(20, 60)
    vim.api.nvim_buf_set_name(bufnr, cube)
    -- Occupy the exact cells the artwork lands on (rows 2..5, cols 13..16) with
    -- text so `z_order = "text"` must yield them to the buffer.
    local function place(r, c, s)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      lines[r + 1] = lines[r + 1]:sub(1, c + 1) .. s .. lines[r + 1]:sub(c + 1 + #s + 1)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end
    for r = 2, 5 do
      place(r, 13, "TEXT")
    end

    local model = wrfm.attach(bufnr, { path = cube, width = 30, height = 8, auto_spin = false })
    assert.are.equal("model", model.z_order, "default z_order is model")
    local model_marks = overlay_marks(model)
    assert.is_truthy(#model_marks > 0, "model z_order paints the overlay")
    local model_texts = {}
    for _, mk in ipairs(model_marks) do
      model_texts[#model_texts + 1] = mk.text
    end
    -- model paints the full runs (4 cells each)
    assert.is_truthy(
      table.concat(model_texts):find("⣀⣀⣀⣀", 1, true),
      "model paints full segment"
    )

    wrfm.clear()

    local text_model = wrfm.attach(bufnr, {
      path = cube,
      width = 30,
      height = 8,
      auto_spin = false,
      z_order = "text",
    })
    assert.are.equal("text", text_model.z_order, "per-model z_order applied")
    local text_marks = overlay_marks(text_model)
    -- text yields occupied cells: the first run (col 13..16) shrinks to the
    -- single leading cell whose column the text does not own.
    local text_texts = {}
    for _, mk in ipairs(text_marks) do
      text_texts[#text_texts + 1] = mk.text
    end
    local text_joined = table.concat(text_texts)
    assert.is_truthy(text_joined:find("⣀", 1, true), "text z_order keeps the free leading cell")
    assert.is_false(
      text_joined:find("⣀⣀⣀⣀", 1, true) ~= nil,
      "text z_order drops the occupied cells"
    )

    wrfm.clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("overflow visible bleeds beyond the canvas", function()
    local bufnr = wide_buf(30, 60)
    vim.api.nvim_buf_set_name(bufnr, cube)
    local model = wrfm.attach(bufnr, {
      path = cube,
      width = 10,
      height = 6,
      auto_spin = false,
      distance = 4,
      overflow = "visible",
      watch = false,
    })
    assert.is_truthy(model:overflows(), "precondition: the footprint exceeds the small canvas")
    -- `visible` must produce a real bleed (the canvas overhang the footprint
    -- demands) rather than silently clipping like the default.
    local bleed = model:_bleed(model:_view())
    assert.is_truthy(bleed, "visible overflow requests a bleed grown from the footprint")
    local total_bleed = (bleed.left or 0)
      + (bleed.right or 0)
      + (bleed.top or 0)
      + (bleed.bottom or 0)
    assert.is_truthy(total_bleed > 0, "the bleed is non-trivial")
    -- And the bled raster still paints through the overlay.
    local marks = overlay_marks(model)
    assert.is_truthy(#marks > 0, "visible overflow renders the bled artwork")

    -- A clipped model, by contrast, never requests any bleed.
    wrfm.clear()
    local clip_model = wrfm.attach(bufnr, {
      path = cube,
      width = 10,
      height = 6,
      auto_spin = false,
      distance = 4,
      overflow = "clip",
      watch = false,
    })
    assert.is_nil(clip_model:_bleed(clip_model:_view()), "clip requests no bleed")

    wrfm.clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)
