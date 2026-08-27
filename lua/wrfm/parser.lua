local M = {}

---@param line string
---@return string
local function strip_comment(line)
  local hash = line:find("#", 1, true)
  if hash then
    return line:sub(1, hash - 1)
  end
  return line
end

---@param token string
---@param what string
---@param lineno integer
---@return number
---@throws on non-finite numbers
local function finite_number(token, what, lineno)
  local value = tonumber(token)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    error(("wrfm:%d: invalid %s '%s'"):format(lineno, what, token), 0)
  end
  return value
end

---@param token string
---@param what string
---@param lineno integer
---@return integer
---@throws on negative or fractional integers
local function integer_token(token, what, lineno)
  local value = finite_number(token, what, lineno)
  if value % 1 ~= 0 or value < 0 then
    error(("wrfm:%d: %s must be a non-negative integer, got '%s'"):format(lineno, what, token), 0)
  end
  return value
end

---Parse `.wrfm` text into `{ vertices = {{x,y,z}...}, edges = {{i,j}...} }`.
-- Elements may pack several per line; groups are sections of the ONE global
-- vertex list (re-listed vertices keep their global file order), so markers
-- carry no geometry and are skipped.
---@param text string full file contents
---@return { vertices: WrfmVec3[], edges: WrfmEdge[] }
---@throws with a `wrfm:<line>` message on malformed input
function M.parse(text)
  local vertices, edges, groups = {}, {}, {}
  local declared_vertices, declared_edges
  local stage = "magic"
  local lineno = 0
  for _, line in (text .. "\n"):gmatch("()(.-)\n") do
    lineno = lineno + 1
    local i = 1
    local tokens = {}
    for token in strip_comment(line):gmatch("%S+") do
      tokens[#tokens + 1] = token
    end
    while i <= #tokens do
      local token = tokens[i]
      if stage == "magic" then
        if token ~= "wrfm" or tokens[i + 1] ~= "1" then
          error(("wrfm:%d: expected magic line 'wrfm 1', got '%s'"):format(lineno, token), 0)
        end
        i = i + 2
        stage = "counts"
      elseif stage == "counts" then
        if token ~= "vertices" and token ~= "edges" then
          error(("wrfm:%d: expected counts 'vertices <N> edges <M>'"):format(lineno), 0)
        end
        local n = integer_token(tokens[i + 1], token .. " count", lineno)
        if token == "vertices" then
          declared_vertices = n
        else
          declared_edges = n
        end
        i = i + 2
        if declared_vertices and declared_edges then
          stage = "body"
        end
      elseif token == "v" then
        if not tokens[i + 3] then
          error(("wrfm:%d: 'v' needs exactly three coordinates"):format(lineno), 0)
        end
        vertices[#vertices + 1] = {
          finite_number(tokens[i + 1], "vertex x", lineno),
          finite_number(tokens[i + 2], "vertex y", lineno),
          finite_number(tokens[i + 3], "vertex z", lineno),
        }
        i = i + 4
      elseif token == "e" then
        if not tokens[i + 2] then
          error(("wrfm:%d: 'e' needs exactly two indices"):format(lineno), 0)
        end
        edges[#edges + 1] = {
          integer_token(tokens[i + 1], "edge index", lineno),
          integer_token(tokens[i + 2], "edge index", lineno),
        }
        i = i + 3
      elseif token == "group" then
        local name = tokens[i + 1]
        if name and name ~= "v" and name ~= "e" and name ~= "group" then
          groups[#groups + 1] = { name = name, start_line = lineno }
          i = i + 2
        else
          groups[#groups + 1] = { name = "(unnamed)", start_line = lineno }
          i = i + 1
        end
      else
        error(("wrfm:%d: unexpected element '%s'"):format(lineno, token), 0)
      end
    end
  end
  if stage == "magic" then
    error("wrfm: empty model file", 0)
  elseif stage == "counts" then
    error("wrfm: missing counts 'vertices <N> edges <M>'", 0)
  end
  if #vertices ~= declared_vertices or #edges ~= declared_edges then
    error(
      ("wrfm: counts mismatch: declared vertices %d edges %d, found %d and %d"):format(
        declared_vertices,
        declared_edges,
        #vertices,
        #edges
      ),
      0
    )
  end
  for k, edge in ipairs(edges) do
    for _, index in ipairs(edge) do
      if index >= #vertices then
        error(("wrfm: edge %d references out-of-range vertex %d"):format(k - 1, index), 0)
      end
    end
  end
  return { vertices = vertices, edges = edges, groups = groups }
end

return M
