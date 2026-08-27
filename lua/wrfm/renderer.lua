local M = {}

M.FOV_DEG = 60
local HALF_FOV = math.rad(M.FOV_DEG / 2)
local FIT_MARGIN = 2
local MIN_DIM = 1e-9
local NEAR = 0.1
local DEFAULT_DISTANCE = 8

-- A braille cell packs eight dots as U+2800 + bitmask, but the bit for a
-- row-major dot index (col + 2*row) is NOT that power of two: Unicode orders
-- the left column as dots 1/2/3/7 (bits 0/1/2/6) and the right as 4/5/6/8.
local DOT_BIT = { 0x01, 0x08, 0x02, 0x10, 0x04, 0x20, 0x40, 0x80 }

local BRAILLE = { " " }
for pattern = 1, 255 do
  local code = 0x2800
  for k = 0, 7 do
    local weight = 2 ^ k
    if pattern % (2 * weight) >= weight then
      code = code + DOT_BIT[k + 1]
    end
  end
  BRAILLE[pattern + 1] = string.char(
    0xE0 + math.floor(code / 0x1000),
    0x80 + math.floor(code / 0x40) % 0x40,
    0x80 + code % 0x40
  )
end

local function set_bit(pattern, k)
  local weight = 2 ^ k
  if pattern % (2 * weight) < weight then
    return pattern + weight
  end
  return pattern
end

---World-frame rotation: turntable yaw around Y, then pitch around X
-- (`rot_y(-yaw) * rot_x(pitch)`, matching wireforge's HUD angles).
-- Kept in closed form: the golden fixtures byte-compare against the wrfm CLI,
-- so this composition must not be rewritten in terms of mat_mul.
---@param pitch number radians
---@param yaw number radians
---@return number[][] 3x3 row-major matrix
function M.rotation(pitch, yaw)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local cy, sy = math.cos(yaw), math.sin(yaw)
  return {
    { cy, -sy * sp, -sy * cp },
    { 0, cp, -sp },
    { sy, cy * sp, cy * cp },
  }
end

-- ---------------------------------------------------------------------------
-- Rotation algebra for incremental view state (wireforge ViewState parity):
-- matrices are 3x3 row-major, model -> world. Pre-multiplying rotates around
-- a world (absolute) axis; post-multiplying rotates around the model's own
-- (relative/local) axis.
-- ---------------------------------------------------------------------------

---Multiply two 3x3 row-major matrices.
---@param a number[][]
---@param b number[][]
---@return number[][]
function M.mat_mul(a, b)
  local c = {}
  for i = 1, 3 do
    local ai = a[i]
    c[i] = {
      ai[1] * b[1][1] + ai[2] * b[2][1] + ai[3] * b[3][1],
      ai[1] * b[1][2] + ai[2] * b[2][2] + ai[3] * b[3][2],
      ai[1] * b[1][3] + ai[2] * b[2][3] + ai[3] * b[3][3],
    }
  end
  return c
end

---Rotation around the world X axis (positive angle tips +Y toward +Z).
---@param a number radians
---@return number[][]
function M.rot_x(a)
  local s, c = math.sin(a), math.cos(a)
  return { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } }
end

---Rotation around the world Y axis (positive angle turns +Z toward +X).
---@param a number radians
---@return number[][]
function M.rot_y(a)
  local s, c = math.sin(a), math.cos(a)
  return { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } }
end

---Project model-space vertices to canvas coordinates (+y up), camera fixed at
-- [0, 0, dist]; `visible[i]` is false for vertices at or behind the near plane.
---@param vertices WrfmVec3[]
---@param rot number[][] rotation matrix from `rotation()`
---@param dist number camera distance
---@param px_h integer canvas height in pixels (dots)
---@return number[] xs screen x per vertex
---@return number[] ys screen y per vertex
---@return boolean[] visible per-vertex near-plane visibility
function M.project(vertices, rot, dist, px_h)
  local focal = (px_h / 2) / math.tan(HALF_FOV)
  local r00, r01, r02 = rot[1][1], rot[1][2], rot[1][3]
  local r10, r11, r12 = rot[2][1], rot[2][2], rot[2][3]
  local r20, r21, r22 = rot[3][1], rot[3][2], rot[3][3]
  local xs, ys, visible = {}, {}, {}
  for i, v in ipairs(vertices) do
    local x, y, z = v[1], v[2], v[3]
    local depth = dist - (r20 * x + r21 * y + r22 * z)
    if depth <= NEAR then
      visible[i] = false
    else
      visible[i] = true
      xs[i] = focal * (r00 * x + r01 * y + r02 * z) / depth
      ys[i] = focal * (r10 * x + r11 * y + r12 * z) / depth
    end
  end
  return xs, ys, visible
end

---Camera distance framing the model: `extent / tan(30deg) * 2`, where extent
-- is the geometric mean of the bounding-box dimensions.
---@param vertices WrfmVec3[]
---@return number
function M.fit_distance(vertices)
  if #vertices == 0 then
    return DEFAULT_DISTANCE
  end
  local min_x, min_y, min_z = math.huge, math.huge, math.huge
  local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
  for _, v in ipairs(vertices) do
    local x, y, z = v[1], v[2], v[3]
    min_x = math.min(min_x, x)
    min_y = math.min(min_y, y)
    min_z = math.min(min_z, z)
    max_x = math.max(max_x, x)
    max_y = math.max(max_y, y)
    max_z = math.max(max_z, z)
  end
  local extent = (
    math.max(max_x - min_x, MIN_DIM)
    * math.max(max_y - min_y, MIN_DIM)
    * math.max(max_z - min_z, MIN_DIM)
  ) ^ (1 / 3)
  return extent / math.tan(HALF_FOV) * FIT_MARGIN
end

---Wrap any angle into [-pi, pi].
---@param angle number radians
---@return number
function M.normalize_angle(angle)
  angle = angle % (2 * math.pi)
  if angle > math.pi then
    angle = angle - 2 * math.pi
  end
  return angle
end

local LEFT, RIGHT, BOTTOM, TOP = 1, 2, 4, 8

local function region_code(x, y, bounds)
  local code = 0
  if x < bounds.left then
    code = code + LEFT
  elseif x > bounds.right then
    code = code + RIGHT
  end
  if y < bounds.bottom then
    code = code + BOTTOM
  elseif y > bounds.top then
    code = code + TOP
  end
  return code
end

-- Cohen-Sutherland region codes pack two exclusive pairs (left/right in bits
-- 0-1, bottom/top in bit 2+), so a shared bit reduces to equal nonzero parts.
local function codes_overlap(a, b)
  local ha, hb = a % 4, b % 4
  local va, vb = math.floor(a / 4), math.floor(b / 4)
  return (ha > 0 and ha == hb) or (va > 0 and va == vb)
end

local function boundary_intersection(x1, y1, x2, y2, code, bounds)
  local dx = x2 - x1
  local dy = y2 - y1
  local horizontal = code % 4
  if horizontal == LEFT then
    return bounds.left, y1 + (bounds.left - x1) * dy / dx
  elseif horizontal == RIGHT then
    return bounds.right, y1 + (bounds.right - x1) * dy / dx
  elseif code == BOTTOM then
    return x1 + (bounds.bottom - y1) * dx / dy, bounds.bottom
  else
    return x1 + (bounds.top - y1) * dx / dy, bounds.top
  end
end

local function clip_segment(x1, y1, x2, y2, bounds)
  local code1 = region_code(x1, y1, bounds)
  local code2 = region_code(x2, y2, bounds)
  while true do
    if codes_overlap(code1, code2) then
      return nil
    elseif code1 > 0 then
      x1, y1 = boundary_intersection(x1, y1, x2, y2, code1, bounds)
      code1 = region_code(x1, y1, bounds)
    elseif code2 > 0 then
      x2, y2 = boundary_intersection(x2, y2, x1, y1, code2, bounds)
      code2 = region_code(x2, y2, bounds)
    else
      return x1, y1, x2, y2
    end
  end
end

-- Round like Rust's f64::round (half away from zero); floor(v + 0.5) is not
-- equivalent because the addition itself can carry for doubles just under .5.
local function round(value)
  local sign = value < 0 and -1 or 1
  value = value * sign
  local floor = math.floor(value)
  if value - floor >= 0.5 then
    floor = floor + 1
  end
  return floor * sign
end

local function snap_to_dot(x, y, bounds, px_w, px_h)
  if x < bounds.left or x > bounds.right or y < bounds.bottom or y > bounds.top then
    return nil
  end
  return round((x - bounds.left) * (px_w - 1) / (bounds.right - bounds.left)),
    round((bounds.top - y) * (px_h - 1) / (bounds.top - bounds.bottom))
end

-- Direction matters for tie-breaks (odd dx flips the diagonal choice), so
-- low/high variants only ever run ascending, like the reference rasterizer.
local function walk_line_low(x1, y1, x2, y2, plot)
  local dx = x2 - x1
  local dy = math.abs(y2 - y1)
  local err = 2 * dy - dx
  local y = y1
  for x = x1, x2 do
    plot(x, y)
    if err > 0 then
      y = y1 > y2 and y - 1 or y + 1
      err = err - 2 * dx
    end
    err = err + 2 * dy
  end
end

local function walk_line_high(x1, y1, x2, y2, plot)
  local dx = math.abs(x2 - x1)
  local dy = y2 - y1
  local err = 2 * dx - dy
  local x = x1
  for y = y1, y2 do
    plot(x, y)
    if err > 0 then
      x = x1 > x2 and x - 1 or x + 1
      err = err - 2 * dy
    end
    err = err + 2 * dx
  end
end

local function walk_line(x1, y1, x2, y2, plot)
  local dx = math.abs(x2 - x1)
  local dy = math.abs(y2 - y1)
  if dx == 0 then
    for y = math.min(y1, y2), math.max(y1, y2) do
      plot(x1, y)
    end
  elseif dy == 0 then
    for x = math.min(x1, x2), math.max(x1, x2) do
      plot(x, y1)
    end
  elseif dy < dx then
    if x1 > x2 then
      walk_line_low(x2, y2, x1, y1, plot)
    else
      walk_line_low(x1, y1, x2, y2, plot)
    end
  elseif y1 > y2 then
    walk_line_high(x2, y2, x1, y1, plot)
  else
    walk_line_high(x1, y1, x2, y2, plot)
  end
end

local function paint_dot(dots, grid_w, px_w, px_h, x, y)
  if x >= px_w or y >= px_h then
    return
  end
  local cell = math.floor(y / 4) * grid_w + math.floor(x / 2) + 1
  dots[cell] = set_bit(dots[cell], (x % 2) + 2 * (y % 4))
end

local function paint_segment(dots, grid_w, bounds, px_w, px_h, x1, y1, x2, y2)
  local ax, ay, bx, by = clip_segment(x1, y1, x2, y2, bounds)
  if not ax then
    return
  end
  local dx1, dy1 = snap_to_dot(ax, ay, bounds, px_w, px_h)
  if not dx1 then
    return
  end
  local dx2, dy2 = snap_to_dot(bx, by, bounds, px_w, px_h)
  if not dx2 then
    return
  end
  walk_line(dx1, dy1, dx2, dy2, function(x, y)
    paint_dot(dots, grid_w, px_w, px_h, x, y)
  end)
end

---Rasterize a wireframe into braille text lines: `view` holds `pitch`, `yaw`
-- (radians), `dist` (camera distance), and canvas size `width` x `height` in
-- character cells (each cell is a 2x4 dot grid). A live viewer passes `rot`
-- (3x3 matrix, see mat_mul) instead; pitch/yaw then only seed static frames.
---@param model { vertices: WrfmVec3[], edges: WrfmEdge[] }
---@param view { rot?: number[][], pitch: number, yaw: number, dist: number, width: integer, height: integer }
---@return string[] exactly `height` lines, right-trimmed (may be empty)
function M.render_frame(model, view)
  local grid_w, grid_h = view.width, view.height
  local px_w, px_h = grid_w * 2, grid_h * 4
  local bounds = {
    left = -px_w / 2,
    right = px_w / 2,
    bottom = -px_h / 2,
    top = px_h / 2,
  }
  local rot = view.rot or M.rotation(view.pitch, view.yaw)
  local xs, ys, visible = M.project(model.vertices, rot, view.dist, px_h)
  local dots = {}
  for i = 1, grid_w * grid_h do
    dots[i] = 0
  end
  for _, edge in ipairs(model.edges) do
    local a, b = edge[1] + 1, edge[2] + 1
    if visible[a] and visible[b] then
      paint_segment(dots, grid_w, bounds, px_w, px_h, xs[a], ys[a], xs[b], ys[b])
    end
  end
  local lines = {}
  for row = 0, grid_h - 1 do
    local base = row * grid_w
    local last = 0
    for col = grid_w, 1, -1 do
      if dots[base + col] > 0 then
        last = col
        break
      end
    end
    local cells = {}
    for col = 1, last do
      cells[col] = BRAILLE[dots[base + col] + 1]
    end
    lines[row + 1] = table.concat(cells)
  end
  return lines
end

return M
