if vim.g.loaded_wrfm then
  return
end
vim.g.loaded_wrfm = true

-- Wireframe color is a config concern: re-apply the configured `highlight`
-- (hex color or theme-group link) from the current wrfm.config, not a fixed
-- Yellow. At plugin load setup() has not run yet, so this applies the default;
-- setup() and set_highlight() re-apply, and this hook re-applies it whenever
-- the colorscheme changes (theme links must track the active palette).
local function set_preview_hl()
  require("wrfm")._apply_highlight()
end
set_preview_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_preview_hl })

local wrfm = require("wrfm")

vim.api.nvim_create_user_command("Wrfm", function(event)
  local path = event.args ~= "" and vim.fs.normalize(vim.fn.expand(event.args))
    or vim.api.nvim_buf_get_name(0)
  if path == "" then
    error("wrfm: no file argument and current buffer is unnamed", 0)
  end
  -- Stable per-file id: repeating :Wrfm re-renders the existing viewer
  -- instead of stacking independent ones.
  wrfm.from_file(path, { id = "file:" .. path }):render()
end, {
  nargs = "?",
  complete = "file",
  desc = "View a .wrfm wireframe model in a floating window",
})

vim.api.nvim_create_user_command("WrfmClear", function(event)
  wrfm.clear(event.args ~= "" and event.args or nil)
end, {
  nargs = "?",
  desc = "Close .wrfm viewers (all of them, or one by id)",
})

vim.api.nvim_create_user_command("WrfmList", function()
  ---@param model WrfmModel
  local function describe(model)
    local mode = model.inline and "inline" or model.winid and "float" or "bound"
    return ("%s\t%s\tspin=%s\t%s"):format(model.id, mode, tostring(model.auto_spin), model.path)
  end
  local models = wrfm.get_models()
  if #models == 0 then
    vim.api.nvim_echo({ { "wrfm: no live models" } }, false, {})
    return
  end
  -- nvim_echo keeps the listing scriptable (:redir captures it).
  vim.api.nvim_echo({ { table.concat(vim.tbl_map(describe, models), "\n") } }, false, {})
end, {
  desc = "List live .wrfm viewers (id, mode, spin state, source path)",
})

vim.api.nvim_create_user_command("WrfmHere", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    error("wrfm: current buffer has no file name", 0)
  end
  wrfm.attach(bufnr, { path = path })
end, {
  desc = "Attach inline wireframe preview to the current buffer",
})

vim.api.nvim_create_user_command("WrfmDetach", function()
  wrfm.detach(vim.api.nvim_get_current_buf())
end, {
  desc = "Detach inline wireframe preview from the current buffer",
})

vim.api.nvim_create_user_command("WrfmReport", function()
  local lines = require("wrfm.report").generate()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 4)
  vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = { { " wrfm report ", "Title" } },
    title_pos = "center",
  })
end, {
  desc = "Show a diagnostic report of all live wrfm models",
})

-- Arm the FileType auto-attach now: waiting for the first attach() would be
-- too late — opening a .wrfm buffer is exactly the flow the hooks serve.
wrfm._ensure_integration_hooks()
