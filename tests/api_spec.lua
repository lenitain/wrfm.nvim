-- API surface: registry, multi-instance management, global switch, commands.
local helpers = require("helpers")
local repo = helpers.repo_dir()
dofile(repo .. "/plugin/wrfm.lua")

local wrfm = require("wrfm")
local api = vim.api

local cube = helpers.fixture_model("cube")
local mocks = helpers.mock_manager()

local function reset()
  vim.o.cmdheight = 1
  wrfm.clear()
  wrfm.enabled = true
end

describe("api", function()
  before_each(function()
    reset()
    mocks:reset()
  end)

  after_each(function()
    mocks:restore_all()
    reset()
  end)

  it("registry", function()
    local first = wrfm.from_file(cube, { auto_spin = false })
    local second = wrfm.from_file(cube, { auto_spin = false })
    assert.are.equal(2, #wrfm.get_models(), "same file twice registers two models")
    assert.are_not.equal(first.id, second.id, "models get distinct default ids")
    assert.is_truthy(first.id:match("^model%-"), "default id uses the model- prefix")

    assert.are.equal(2, #wrfm.get_models({ id = second.id }), "unknown filter keys are ignored")
    wrfm.clear(second.id)
    assert.are.equal(1, #wrfm.get_models(), "clear(id) removes exactly one model")
    assert.are.equal(first.id, wrfm.get_models()[1].id, "the surviving model is the untouched one")
    assert.is_nil(wrfm.current, "clearing the current model clears the cursor")
    wrfm.clear()
    assert.are.equal(0, #wrfm.get_models(), "clear() with no argument destroys every model")

    wrfm.clear("no-such-id")
    assert.are.equal(0, #wrfm.get_models(), "clear(unknown id) is a safe no-op")
  end)

  it("get_models filters", function()
    local float_model = wrfm.from_file(cube, { width = 20, height = 6, auto_spin = false })
    float_model:render()

    local host = api.nvim_create_buf(true, false)
    local bound_model = wrfm.from_file(cube, { buffer = host, auto_spin = false })
    bound_model:render()

    assert.are.equal(
      1,
      #wrfm.get_models({ window = float_model.winid }),
      "window filter hits the float"
    )
    assert.are.equal(
      float_model,
      wrfm.get_models({ window = float_model.winid })[1],
      "window filter identity"
    )
    assert.are.equal(1, #wrfm.get_models({ buffer = host }), "buffer filter hits the bound model")
    assert.are.equal(bound_model, wrfm.get_models({ buffer = host })[1], "buffer filter identity")
    assert.are.equal(
      0,
      #wrfm.get_models({ window = float_model.winid, buffer = host }),
      "filters combine conjunctively"
    )
    assert.are.equal(2, #wrfm.get_models({}), "empty opts lists everything")

    reset()
    assert.is_true(api.nvim_buf_is_valid(host), "foreign buffers survive teardown")
  end)

  it("from_file reuses a live id", function()
    local first = wrfm.from_file(cube, { id = "x", auto_spin = false })
    local second = wrfm.from_file(cube, { id = "x", width = 99, auto_spin = false })
    assert.are.equal(first, second, "from_file with a live id returns the existing model")
    assert.are.equal(1, #wrfm.get_models(), "no duplicate model is registered")
    assert.is_nil(first.width_opt, "options from the repeat call are ignored")
    assert.are.equal(first, wrfm.current, "reuse makes the model current again")

    wrfm.clear("x")
    local fresh = wrfm.from_file(cube, { id = "x", auto_spin = false })
    assert.are_not.equal(first, fresh, "a cleared id can be created anew")
  end)

  it("attach is idempotent per buffer", function()
    local host = api.nvim_create_buf(true, false)
    -- The overlay can only land on real lines that are wide enough to hold the
    -- artwork, so give the buffer enough rows/columns.
    local lines = {}
    for _ = 1, 20 do
      lines[#lines + 1] = string.rep(" ", 60)
    end
    api.nvim_buf_set_lines(host, 0, -1, false, lines)
    api.nvim_buf_set_name(host, cube)
    local first = wrfm.attach(host, { path = cube, width = 24, height = 8, auto_spin = false })
    local second = wrfm.attach(host, { path = cube, width = 30, height = 10, auto_spin = false })
    assert.are.equal(first, second, "second attach returns the existing model")
    assert.are.equal(1, #wrfm.get_models({ buffer = host }), "one inline model per buffer")
    -- Re-attach re-renders the same model, so the namespace holds exactly the
    -- marks the model tracks: no stacked or orphaned extmarks.
    assert.are.equal(
      #api.nvim_buf_get_extmarks(host, wrfm.inline_ns, 0, -1, {}),
      #(first.inline_extmark_ids or {}),
      "no stacked or leaked extmarks"
    )
    pcall(api.nvim_buf_delete, host, { force = true })
  end)

  it("clear(id) destroys every match", function()
    wrfm.from_file(cube, { id = "dup", auto_spin = false })
    local ghost = wrfm.from_file(cube, { auto_spin = false })
    ghost.id = "dup"
    assert.are.equal(2, #wrfm.get_models(), "precondition: two models carry the id")
    wrfm.clear("dup")
    assert.are.equal(0, #wrfm.get_models(), "clear(id) destroys every matching model")
    wrfm.clear("no-such-id")
    assert.are.equal(0, #wrfm.get_models(), "clear(unknown id) is a safe no-op")
  end)

  it("hide / show roundtrip", function()
    local model =
      wrfm.from_file(cube, { id = "roundtrip", width = 20, height = 6, spin_speed = 0.3 })
    model:render()
    assert.is_truthy(model.timer and model.timer:is_active(), "precondition: spin timer running")
    assert.is_truthy(model.watch_started, "precondition: disk watcher running")

    model:hide()
    assert.are.equal(1, #wrfm.get_models(), "hide keeps the model registered")
    assert.is_nil(model.winid, "hide closes the float")
    assert.is_truthy(model.watcher, "hide keeps the disk watcher alive")
    assert.is_nil(model.timer, "hide stops and drops the spin timer")
    assert.is_nil(model._focus_stopped, "focus pause marker cleared by hide")
    assert.is_nil(model._suspend_stopped, "suspend pause marker cleared by hide")

    api.nvim_exec_autocmds("FocusGained", {})
    assert.is_nil(model.timer, "FocusGained never resurrects a hidden model's timer")

    model.pitch = 0.42
    model.yaw = 0.17
    assert.is_true(model:show(), "show() renders")
    assert.is_truthy(
      model.winid and api.nvim_win_is_valid(model.winid),
      "show() rebuilds the float"
    )
    assert.is.near(0.42, model.pitch, 1e-9, "pitch survives hide/show")
    assert.is.near(0.17, model.yaw, 1e-9, "yaw survives hide/show")

    local second = wrfm.from_file(cube, { id = "second", width = 20, height = 6 })
    second:render()
    wrfm.hide()
    assert.is_nil(model.winid, "M.hide() hides every view")
    assert.is_nil(second.winid, "M.hide() covers late models too")
    wrfm.show("second")
    assert.is_truthy(
      second.winid and api.nvim_win_is_valid(second.winid),
      "M.show(id) targets one model"
    )
    assert.is_nil(model.winid, "other models stay hidden")
    wrfm.show()
    assert.is_truthy(
      model.winid and api.nvim_win_is_valid(model.winid),
      "M.show() restores everything"
    )

    wrfm.disable()
    assert.is_false(model:show(), "show() while disabled returns false")
  end)

  it("disable / enable roundtrip", function()
    local model = wrfm.from_file(cube, { auto_spin = false })
    model:render()
    assert.is_truthy(
      model.winid and api.nvim_win_is_valid(model.winid),
      "precondition: window open"
    )

    assert.is_nil(wrfm.disable(), "disable returns nil")
    assert.is_false(wrfm.is_enabled(), "is_enabled false after disable")
    assert.is_nil(model.winid, "disable closes the float")
    assert.are.equal(1, #wrfm.get_models(), "disable keeps the model registered")
    assert.is_false(api.nvim_buf_is_valid(model.bufnr or -1), "disable wipes the scratch buffer")

    assert.is_false(model:render(), "render while disabled is a silent no-op returning false")
    assert.is_nil(model.winid, "disabled render opens nothing")

    local hidden = wrfm.from_file(cube, { auto_spin = false })
    assert.is_truthy(hidden, "from_file stays legal while disabled")

    wrfm.enable()
    assert.is_true(wrfm.is_enabled(), "is_enabled true after enable")
    assert.is_truthy(
      model.winid and api.nvim_win_is_valid(model.winid),
      "enable re-renders existing models"
    )
    assert.is_truthy(
      hidden.winid and api.nvim_win_is_valid(hidden.winid),
      "enable covers models built while disabled"
    )
    assert.are.equal(2, #wrfm.get_models(), "registry intact across the roundtrip")
  end)

  it("disabled roundtrip for bound buffers", function()
    local host = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(host, 0, -1, false, { "keep me" })
    local bound = wrfm.from_file(cube, { buffer = host, auto_spin = false })
    bound:render()
    assert.are_not.equal(
      "keep me",
      api.nvim_buf_get_lines(host, 0, -1, false)[1],
      "bound mode painted content"
    )

    wrfm.disable()
    assert.are.equal(
      "keep me",
      api.nvim_buf_get_lines(host, 0, -1, false)[1],
      "disable restores the bound buffer's content"
    )
    assert.is_false(bound:render(), "disabled re-render of bound buffer is a no-op")
    wrfm.enable()
    assert.are.equal(host, bound.bufnr, "enable redraws into the same bound buffer")
    assert.is_true(
      #api.nvim_buf_get_lines(host, 0, -1, false) > 0,
      "bound buffer repainted after enable"
    )
  end)

  it("ftdetect maps .wrfm files", function()
    dofile(repo .. "/ftdetect/wrfm.lua")
    assert.are.equal(
      "wrfm",
      vim.filetype.match({ filename = "/tmp/anywhere/model.wrfm" }),
      ".wrfm extension resolves to the wrfm filetype"
    )
    assert.is_nil(
      vim.filetype.match({ filename = "/tmp/anywhere/model.wrfmx" }),
      "other extensions stay untouched"
    )
  end)

  it("opening a .wrfm buffer auto-attaches", function()
    dofile(repo .. "/ftdetect/wrfm.lua")
    wrfm._ensure_integration_hooks()

    local path = helpers.fixture_model("cube")
    local bufnr = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(bufnr, path)
    vim.bo[bufnr].filetype = "wrfm"

    local models = wrfm.get_models({ buffer = bufnr })
    assert.are.equal(1, #models, "FileType arms the inline preview automatically")
    if models[1] then
      assert.is_truthy(models[1].inline, "auto-attached model is an inline preview")
      assert.is_false(models[1].only_render_at_cursor, "defaults apply to auto-attach")
    end
    wrfm.detach(bufnr)
    pcall(api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("command smoke", function()
    vim.cmd(("Wrfm %s"):format(cube))
    local file_viewer = wrfm.get_models()[1]
    vim.cmd(("Wrfm %s"):format(cube))
    assert.are.equal(1, #wrfm.get_models(), ":Wrfm twice reuses one viewer (stable per-file id)")
    assert.are.equal(file_viewer, wrfm.get_models()[1], "the reused viewer keeps its identity")

    vim.cmd("redir => g:wrfm_list_capture")
    vim.cmd("silent WrfmList")
    vim.cmd("redir END")
    local text = vim.g.wrfm_list_capture or ""
    vim.g.wrfm_list_capture = nil
    assert.is_truthy(text:find("file:", 1, true), ":WrfmList prints ids")
    assert.is_truthy(text:find("cube.wrfm", 1, true), ":WrfmList prints paths")

    wrfm.from_file(cube, { auto_spin = false })
    assert.are.equal(2, #wrfm.get_models(), "from_file without an id stays independent")
    vim.cmd(("WrfmClear %s"):format(file_viewer.id))
    assert.are.equal(1, #wrfm.get_models(), ":WrfmClear <id> closes just that viewer")
    assert.are_not.equal(file_viewer, wrfm.get_models()[1], "the independent viewer survived")
    vim.cmd("WrfmClear")
    assert.are.equal(0, #wrfm.get_models(), ":WrfmClear with no id closes every viewer")
    assert.is_nil(wrfm.current, "command layer cursor follows teardown")
  end)

  it("move repositions the float", function()
    local model = wrfm.from_file(cube, { width = 20, height = 6, auto_spin = false })
    model:render()
    assert.is_truthy(
      model.winid and api.nvim_win_is_valid(model.winid),
      "precondition: window open"
    )

    model:move(10, 5)
    local cfg = api.nvim_win_get_config(model.winid)
    assert.are.equal(10, cfg.col, "move sets the editor-relative column")
    assert.are.equal(5, cfg.row, "move sets the editor-relative row")
    assert.are.equal(20, cfg.width, "move preserves the canvas width")

    model:hide()
    model:render()
    local fresh = api.nvim_win_get_config(model.winid)
    assert.is_truthy(fresh.col ~= 10 or fresh.row ~= 5, "hide/render drops the manual placement")

    model:clear()
    model:move(3, 3)
  end)

  it("move on inline model is a no-op", function()
    local host = api.nvim_create_buf(true, false)
    local model = wrfm.attach(host, { path = cube })
    assert.is_nil(model.winid, "precondition: inline mode has no float")
    assert.is_true(pcall(model.move, model, 4, 4), "move without a float raises nothing")
    assert.is_nil(model.winid, "inline model stays window-less after move")
  end)

  it("render(geometry) resizes the canvas", function()
    local model = wrfm.from_file(cube, { width = 40, height = 12, auto_spin = false })
    model:render()

    assert.is_true(model:render({ width = 20, height = 6 }), "render(geometry) renders")
    local cfg = api.nvim_win_get_config(model.winid)
    assert.are.equal(20, cfg.width, "float follows the new width")
    assert.are.equal(6, cfg.height, "float follows the new height")
    assert.are.equal(
      6,
      #api.nvim_buf_get_lines(model.bufnr, 0, -1, false),
      "buffer repainted at the new canvas height"
    )

    model:render()
    assert.are.equal(
      20,
      api.nvim_win_get_config(model.winid).width,
      "geometry persists across render()"
    )

    model:render({ width = 30 })
    assert.are.equal(30, api.nvim_win_get_config(model.winid).width, "partial update applies width")
    assert.are.equal(6, api.nvim_win_get_config(model.winid).height, "partial update keeps height")

    wrfm.disable()
    assert.is_false(model:render({ width = 10 }), "disabled render(geometry) returns false")
  end)

  it("namespace filter", function()
    local tagged = wrfm.from_file(cube, { auto_spin = false, namespace = "preview" })
    local untagged = wrfm.from_file(cube, { auto_spin = false })

    assert.are.equal("preview", tagged.namespace, "from_file stores the namespace tag")
    assert.is_nil(untagged.namespace, "namespace stays nil when not given")

    local hits = wrfm.get_models({ namespace = "preview" })
    assert.are.equal(1, #hits, "namespace filter matches only tagged models")
    assert.are.equal(tagged, hits[1], "namespace filter identity")
    assert.are.equal(2, #wrfm.get_models({}), "empty opts ignores namespaces")
    assert.are.equal(
      0,
      #wrfm.get_models({ namespace = "other" }),
      "unknown namespace matches nothing"
    )

    tagged:render()
    assert.are.equal(
      1,
      #wrfm.get_models({ namespace = "preview", window = tagged.winid }),
      "namespace combines with the window filter"
    )
    assert.are.equal(
      0,
      #wrfm.get_models({ namespace = "preview", window = -1 }),
      "namespace combines conjunctively"
    )
  end)

  it("WrfmReport shows every live model", function()
    local first = wrfm.from_file(cube, { width = 20, height = 6, auto_spin = false })
    local second =
      wrfm.from_file(cube, { width = 24, height = 8, auto_spin = false, namespace = "report-test" })

    vim.cmd("WrfmReport")

    local report_win = nil
    for _, winid in ipairs(api.nvim_list_wins()) do
      local cfg = api.nvim_win_get_config(winid)
      local title = cfg.title
      if type(title) == "table" and title[1] and title[1][1] == " wrfm report " then
        report_win = winid
        break
      end
    end
    assert.is_truthy(report_win, ":WrfmReport opens its floating window")
    if report_win then
      local lines =
        table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(report_win), 0, -1, false), "\n")
      assert.is_truthy(lines:find(first.id, 1, true), "report lists the first model id")
      assert.is_truthy(lines:find(second.id, 1, true), "report lists the second model id")
      assert.is_truthy(lines:find("cube.wrfm", 1, true), "report lists source paths")
      assert.is_truthy(lines:find("report-test", 1, true), "report lists namespace tags")
      assert.is_truthy(lines:find("neovim:", 1, true), "report includes the Neovim version")
      api.nvim_win_close(report_win, true)
    end

    wrfm.clear()
    vim.cmd("WrfmReport")
    report_win = nil
    for _, winid in ipairs(api.nvim_list_wins()) do
      local cfg = api.nvim_win_get_config(winid)
      if type(cfg.title) == "table" and cfg.title[1] and cfg.title[1][1] == " wrfm report " then
        report_win = winid
        break
      end
    end
    if report_win then
      local lines =
        table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(report_win), 0, -1, false), "\n")
      assert.is_truthy(lines:find("models: none live", 1, true), "empty registry reports no models")
      api.nvim_win_close(report_win, true)
    end
  end)
end)
