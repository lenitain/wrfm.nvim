-- Minimal wrfm.nvim demo.
--
--   nvim --clean -c "luafile examples/minimal.lua"
--
-- Writes a small cube model to a temp file, adds this repo to the
-- runtimepath, and opens a spinning braille viewer.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(repo)
vim.cmd("runtime plugin/wrfm.lua")

local path = vim.fn.tempname() .. ".wrfm"
local file = io.open(path, "w")
file:write([[
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
]])
file:close()

local wrfm = require("wrfm")
wrfm.from_file(path):render()

print("wrfm minimal demo — type :qa to quit")
