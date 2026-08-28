-- Highlight resolution for wireframe rendering.
--
-- Every render path (float buffer, inline virt_text, popup) colors the
-- braille art through the single WrfmPreview highlight group, which Neovim
-- resolves by name at draw time. Redefining the group recolors all live
-- views instantly, so this module only has to translate the user-facing
-- `highlight` config value into an nvim_set_hl definition:
--
--   - "#RRGGBB"  -> literal foreground color
--   - any other string -> link to that theme highlight group
--
-- The two forms map exactly onto the two ways nvim_set_hl colors a group:
-- `fg` paints a fixed value, `link` inherits whatever the active colorscheme
-- gives another group (and keeps following it across colorscheme changes).

local M = {}

local GROUP = "WrfmPreview"

-- Neovim parses exactly "#RRGGBB" (6 hex digits) for fg/bg.
local HEX_PATTERN = "^#[%x][%x][%x][%x][%x][%x]$"

---Whether `value` is a `#RRGGBB` hex color (case-insensitive).
---@param value unknown
---@return boolean
function M.is_hex(value)
  if type(value) ~= "string" then
    return false
  end
  return value:match(HEX_PATTERN) ~= nil
end

---Translate a user-facing `highlight` value into an nvim_set_hl definition.
---@param value string a hex color ("#RRGGBB") or a highlight group to link
---@return table definition for nvim_set_hl (fg or link, no `default` key)
function M.resolve(value)
  if type(value) ~= "string" then
    error(
      ("wrfm: highlight must be a string (hex color or group name), got %s"):format(type(value)),
      0
    )
  end
  if value:sub(1, 1) == "#" then
    if not M.is_hex(value) then
      error(("wrfm: invalid hex color '%s' (expected #RRGGBB)"):format(value), 0)
    end
    return { fg = value }
  end
  return { link = value }
end

---Apply a `highlight` value to the global WrfmPreview group.
---@param value string a hex color ("#RRGGBB") or a highlight group to link
---@param opts? { force?: boolean } force=true when the user explicitly
---   configured this value, so the definition always wins. Otherwise the
---   group stays a theme-friendly fallback (`default = true`): a colorscheme
---   that defines WrfmPreview itself still takes precedence, matching the
---   pre-config behavior.
function M.apply(value, opts)
  opts = opts or {}
  local def = M.resolve(value)
  def.default = not opts.force
  vim.api.nvim_set_hl(0, GROUP, def)
end

return M
