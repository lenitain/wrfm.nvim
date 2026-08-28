-- highlight config: hex color vs theme-group link, validation, live recolor.
local helpers = require("helpers")
local repo = helpers.repo_dir()
dofile(repo .. "/plugin/wrfm.lua")

local wrfm = require("wrfm")
local hl = require("wrfm.highlight")
local api = vim.api

local cube = helpers.fixture_model("cube")

-- nvim_get_hl(link=true) shows the raw definition (a `link` field for linked
-- groups); link=false resolves it to effective attributes.
local function raw_def()
  return api.nvim_get_hl(0, { name = "WrfmPreview", link = true })
end

local function eff_def()
  return api.nvim_get_hl(0, { name = "WrfmPreview", link = false })
end

describe("highlight", function()
  before_each(function()
    wrfm.setup({ highlight = "Yellow" })
  end)

  after_each(function()
    wrfm.clear()
  end)

  it("config default links the theme Yellow group", function()
    assert.are.equal("Yellow", wrfm.config.highlight)
    assert.are.equal(
      "Yellow",
      raw_def().link,
      "default WrfmPreview is a theme link, not a literal color"
    )
  end)

  it("hex color paints a literal foreground", function()
    wrfm.setup({ highlight = "#ff8800" })
    assert.are.equal(0xff8800, eff_def().fg, "hex color becomes the fg attribute")
    assert.is_nil(raw_def().link, "hex color is not a link")
  end)

  it("group name reads the active colorscheme", function()
    wrfm.setup({ highlight = "Function" })
    assert.are.equal("Function", raw_def().link, "WrfmPreview links to the configured group")
  end)

  it("explicit config survives a colorscheme switch", function()
    wrfm.setup({ highlight = "PreProc" })
    api.nvim_exec_autocmds("ColorScheme", {})
    assert.are.equal("PreProc", raw_def().link, "ColorScheme re-apply keeps the configured link")

    wrfm.set_highlight("#00ff88")
    api.nvim_exec_autocmds("ColorScheme", {})
    assert.are.equal(0x00ff88, eff_def().fg, "ColorScheme re-apply keeps the configured hex")
  end)

  it("set_highlight recollors live models in place", function()
    local model = wrfm.from_file(cube, { width = 20, height = 6, auto_spin = false })
    model:render()
    assert.is_truthy(
      model.winid and api.nvim_win_is_valid(model.winid),
      "precondition: model rendered"
    )

    wrfm.set_highlight("#ff8800")
    assert.are.equal(0xff8800, eff_def().fg, "group redefinition recolors without a re-render")
    assert.is_truthy(
      api.nvim_win_is_valid(model.winid),
      "model stays on screen while recolor happens"
    )
  end)

  it("fallback apply does not override a theme's own definition", function()
    api.nvim_set_hl(0, "WrfmPreview", { link = "Identifier" }) -- simulate a theme defining the group
    hl.apply("PreProc", { force = false })
    assert.are.equal(
      "Identifier",
      raw_def().link,
      "unset config stays a theme-friendly fallback (default = true)"
    )
    hl.apply("PreProc", { force = true })
    assert.are.equal("PreProc", raw_def().link, "explicit config forces the definition")
  end)

  it("rejects malformed highlight values", function()
    assert.has_error(function()
      wrfm.setup({ highlight = "#12" })
    end)
    assert.has_error(function()
      wrfm.setup({ highlight = "#1234567" })
    end)
    assert.has_error(function()
      wrfm.setup({ highlight = "#gggggg" })
    end)
    assert.has_error(function()
      wrfm.setup({ highlight = 42 })
    end)
    -- a failed setup() must not leave the module broken: config keeps the
    -- last valid value and a plain setup() still works.
    assert.are.equal("Yellow", wrfm.config.highlight, "invalid highlight leaves config untouched")
    wrfm.setup({ fps = 30 })
    assert.are.equal(30, wrfm.config.fps, "setup() still works after a rejected highlight")
  end)
end)
