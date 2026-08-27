-- Shared test utilities for wrfm.nvim specs.
-- Provides: path helpers, buffer helpers, env helpers, mock manager, fixture factory.
local M = {}

local uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Path helpers
-- ---------------------------------------------------------------------------

function M.repo_dir()
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  return vim.fs.dirname(here)
end

function M.fixture_model(name)
  return M.repo_dir() .. "/tests/fixtures/models/" .. name .. ".wrfm"
end

function M.read_file(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  return text
end

function M.write_file(path, text)
  local f = io.open(path, "w")
  if not f then
    error("cannot open " .. path .. " for writing", 0)
  end
  f:write(text)
  f:close()
end

-- ---------------------------------------------------------------------------
-- Buffer helpers
-- ---------------------------------------------------------------------------

function M.load_buf(path)
  local bufnr = vim.api.nvim_create_buf(true, false)
  local text = M.read_file(path)
  if not text then
    error("cannot open " .. path, 0)
  end
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { line })
  end
  vim.bo[bufnr].modified = false
  return bufnr
end

function M.braille_cells(bufnr)
  local count = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line ~= "" then
      count = count + vim.fn.strchars(line)
    end
  end
  return count
end

-- ---------------------------------------------------------------------------
-- Environment helpers (terminal size, wrfm state)
-- ---------------------------------------------------------------------------

local _saved_env = {}

function M.prepare(opts)
  opts = opts or {}
  _saved_env.columns = vim.o.columns
  _saved_env.lines = vim.o.lines
  _saved_env.cmdheight = vim.o.cmdheight
  vim.o.columns = opts.columns or 120
  vim.o.lines = opts.lines or 40
  vim.o.cmdheight = 1
  local wrfm = require("wrfm")
  wrfm.clear()
end

function M.restore_env()
  if _saved_env.columns then
    vim.o.columns = _saved_env.columns
  end
  if _saved_env.lines then
    vim.o.lines = _saved_env.lines
  end
  if _saved_env.cmdheight then
    vim.o.cmdheight = _saved_env.cmdheight
  end
end

-- ---------------------------------------------------------------------------
-- Mock manager — reliable stub/restore with automatic teardown
-- ---------------------------------------------------------------------------
-- Usage:
--   local mocks = helpers.mock_manager()
--   before_each(function() mocks:reset() end)
--   after_each(function()  mocks:restore_all() end)
--
--   -- in a test:
--   mocks:stub(vim, "notify_once", function(msg) ... end)
--   mocks:stub(model, "_repaint", function(self) ... end)
--   -- mocks are auto-restored in after_each

local mock_meta = {}

function mock_meta:reset()
  self._stubs = {}
end

function mock_meta:stub(obj, key, replacement)
  local original = obj[key]
  self._stubs[#self._stubs + 1] = { obj = obj, key = key, original = original }
  obj[key] = replacement
  return original
end

function mock_meta:restore_all()
  for i = #self._stubs, 1, -1 do
    local s = self._stubs[i]
    s.obj[s.key] = s.original
  end
  self._stubs = {}
end

M.mock_manager = setmetatable({}, {
  __call = function()
    local mgr = { _stubs = {} }
    setmetatable(mgr, { __index = mock_meta })
    return mgr
  end,
})

-- ---------------------------------------------------------------------------
-- Fixture factory — programmatic .wrfm model builder
-- ---------------------------------------------------------------------------
-- Usage:
--   local model_text = helpers.fixture({
--     vertices = { {0,0,0}, {1,0,0}, {0,1,0} },
--     edges = { {0,1}, {1,2}, {2,0} },
--   })
--   local path = helpers.tmp_fixture(model_text)

function M.fixture(spec)
  local v = spec.vertices
  local e = spec.edges
  local groups = spec.groups

  local lines = { "wrfm 1" }
  local vcount = #v
  if groups then
    for _, g in ipairs(groups) do
      vcount = vcount + #g.vertices
    end
  end
  lines[#lines + 1] = ("vertices %d edges %d"):format(vcount, #e)
  lines[#lines + 1] = ""

  for _, p in ipairs(v) do
    lines[#lines + 1] = ("v %g %g %g"):format(p[1], p[2], p[3])
  end

  if groups then
    for _, g in ipairs(groups) do
      lines[#lines + 1] = ""
      lines[#lines + 1] = "group " .. g.name
      for _, p in ipairs(g.vertices) do
        lines[#lines + 1] = ("v %g %g %g"):format(p[1], p[2], p[3])
      end
    end
  end

  lines[#lines + 1] = ""
  for _, edge in ipairs(e) do
    lines[#lines + 1] = ("e %d %d"):format(edge[1], edge[2])
  end
  lines[#lines + 1] = ""

  return table.concat(lines, "\n")
end

function M.tmp_fixture(text)
  local path = vim.fn.tempname() .. ".wrfm"
  M.write_file(path, text)
  return path
end

-- Pre-built fixture specs for common topologies.

function M.fixture_cube()
  return {
    vertices = {
      { -1, -1, -1 },
      { 1, -1, -1 },
      { 1, 1, -1 },
      { -1, 1, -1 },
      { -1, -1, 1 },
      { 1, -1, 1 },
      { 1, 1, 1 },
      { -1, 1, 1 },
    },
    edges = {
      { 0, 1 },
      { 1, 2 },
      { 2, 3 },
      { 3, 0 },
      { 4, 5 },
      { 5, 6 },
      { 6, 7 },
      { 7, 4 },
      { 0, 4 },
      { 1, 5 },
      { 2, 6 },
      { 3, 7 },
    },
  }
end

function M.fixture_tetra()
  return {
    vertices = { { 1, 1, 1 }, { 1, -1, -1 }, { -1, 1, -1 }, { -1, -1, 1 } },
    edges = { { 0, 1 }, { 0, 2 }, { 0, 3 }, { 1, 2 }, { 1, 3 }, { 2, 3 } },
  }
end

function M.fixture_line()
  return {
    vertices = { { 0, 0, 0 }, { 1, 0, 0 } },
    edges = { { 0, 1 } },
  }
end

function M.fixture_point()
  return {
    vertices = { { 0, 0, 0 }, { 0, 0, 0 } },
    edges = { { 0, 1 } },
  }
end

function M.fixture_degree1()
  return {
    vertices = { { 0, 0, 0 }, { 1, 0, 0 }, { 2, 0, 0 } },
    edges = { { 0, 1 } },
  }
end

function M.fixture_large(n)
  local v = {}
  local e = {}
  for i = 0, n - 1 do
    local angle = 2 * math.pi * i / n
    v[#v + 1] = { math.cos(angle), 0, math.sin(angle) }
    v[#v + 1] = { math.cos(angle), 1, math.sin(angle) }
  end
  for i = 0, n - 1 do
    local base = i * 2
    local next_base = ((i + 1) % n) * 2
    e[#e + 1] = { base, next_base }
    e[#e + 1] = { base + 1, next_base + 1 }
    e[#e + 1] = { base, base + 1 }
  end
  return { vertices = v, edges = e }
end

function M.fixture_open_chain()
  return {
    vertices = { { 0, 0, 0 }, { 1, 0, 0 }, { 2, 0, 0 }, { 3, 0, 0 } },
    edges = { { 0, 1 }, { 1, 2 }, { 2, 3 } },
  }
end

return M
