#!/usr/bin/env -S nvim -l

vim.env.LAZY_STDPATH = ".tests"

-- hererocks compiles Lua 5.1 with LUA_USE_READLINE on Linux and needs readline headers
local function has_readline_headers()
  local roots = { "/usr/include", "/usr/local/include" }
  for dir in vim.gsplit(vim.env.CPATH or "", ":", { trimempty = true }) do
    table.insert(roots, dir)
  end
  for _, root in ipairs(roots) do
    if vim.uv.fs_stat(root .. "/readline/readline.h") then
      return true
    end
  end
end

if vim.uv.os_uname().sysname == "Linux" and not has_readline_headers() then
  error(
    "missing readline headers: install libreadline-dev (Debian/Ubuntu), "
      .. "readline-devel (Fedora/RHEL) or the equivalent of your distribution"
  )
end

local raw = vim.env.GITHUB_RAW_URL or "https://raw.githubusercontent.com"
load(vim.fn.system("curl -fsSL " .. raw .. "/folke/lazy.nvim/main/bootstrap.lua"))()

require("lazy.minit").busted({})
