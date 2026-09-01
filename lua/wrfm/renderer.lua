local M = {}

-- Field of view the reference rasterizer (and every golden frame) assumes.
-- FOV decides how much of the world a viewport shows; distance decides how far
-- away the model sits and therefore how strong the perspective is. The two are
-- independent knobs: a wider FOV at the same distance grows the art without
-- flattening the depth.
M.FOV_DEG = 60
local FIT_MARGIN = 2
local MIN_DIM = 1e-9
local NEAR = 0.1
local DEFAULT_DISTANCE = 8

---`tan(fov / 2)`, the projection's angular scale. Leaving the default unset
---returns the exact constant the CLI path divides by today.
---@param fov_deg? integer|number field of view in degrees (default `M.FOV_DEG`)
---@return number
local function half_fov_tan(fov_deg)
  return math.tan(math.rad((fov_deg or M.FOV_DEG) / 2))
end

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

---Project model-space vertices to screen coordinates (+y up), camera fixed at
-- [0, 0, dist]; `visible[i]` is false for vertices at or behind the near plane.
-- `ref_h` is the height, in dot rows, of the viewport the field of view
-- subtends: it fixes dots-per-world-unit, and with it the projected footprint.
---@param vertices WrfmVec3[]
---@param rot number[][] rotation matrix from `rotation()`
---@param dist number camera distance
---@param ref_h integer viewport height in dots (px rows)
---@param fov_deg? number field of view in degrees (default `M.FOV_DEG`)
---@return number[] xs screen x per vertex
---@return number[] ys screen y per vertex
---@return boolean[] visible per-vertex near-plane visibility
function M.project(vertices, rot, dist, ref_h, fov_deg)
  local focal = (ref_h / 2) / half_fov_tan(fov_deg)
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

---Geometric mean of a model's bounding-box dimensions (world units): the extent
-- auto-fit frames from, and the only geometry-dependent part of `fit_distance`.
---@param vertices WrfmVec3[]
---@return number
function M.model_extent(vertices)
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
  return (
    math.max(max_x - min_x, MIN_DIM)
    * math.max(max_y - min_y, MIN_DIM)
    * math.max(max_z - min_z, MIN_DIM)
  ) ^ (1 / 3)
end

---Camera distance framing `extent` (see `model_extent`) into a canvas: half the
-- viewport subtends `fov/2`, and the framed model fills `canvas_h / FIT_MARGIN`
-- dots. `ref_h == canvas_h` (a plain CLI render) leaves the distance
-- bit-identical to the unscaled formula.
---@param extent number
---@param ref_h? integer viewport height in dots the FOV subtends
---@param canvas_h? integer canvas height in dots (the box the model is framed into)
---@param fov_deg? number field of view in degrees (default `M.FOV_DEG`)
---@return number
function M.frame_distance(extent, ref_h, canvas_h, fov_deg)
  -- Exactly 1.0 in binary when the viewport is the canvas, so parity holds.
  local frame_ratio = ref_h and canvas_h and (ref_h / canvas_h) or 1
  return extent / half_fov_tan(fov_deg) * FIT_MARGIN * frame_ratio
end

---Camera distance framing the model into its canvas (see `model_extent` and
-- `frame_distance`; empty geometry falls back to a nominal distance).
---@param vertices WrfmVec3[]
---@param ref_h? integer viewport height in dots the FOV subtends
---@param canvas_h? integer canvas height in dots (the box the model is framed into)
---@param fov_deg? number field of view in degrees (default `M.FOV_DEG`)
---@return number
function M.fit_distance(vertices, ref_h, canvas_h, fov_deg)
  if #vertices == 0 then
    return DEFAULT_DISTANCE
  end
  return M.frame_distance(M.model_extent(vertices), ref_h, canvas_h, fov_deg)
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

-- ---------------------------------------------------------------------------
-- Rasterizer output types
-- ---------------------------------------------------------------------------

---@class WrfmRect 屏幕单位矩形（+y 向上）
---@field left number
---@field right number
---@field top number
---@field bottom number

---@class WrfmBleed 允许越出画布的格数（默认 0 = 裁到画布）
---@field left? integer 画布左侧还可画的格数
---@field right? integer 画布右侧还可画的格数
---@field top? integer 画布上方还可画的格数
---@field bottom? integer 画布下方还可画的格数

---@class WrfmRasterOptions
---@field bleed? WrfmBleed

---@class WrfmView 一帧的相机与裁剪框
---@field rot? number[][] 3x3 rotation matrix; without it, pitch/yaw seed the frame
---@field pitch number radians
---@field yaw number radians
---@field dist number camera distance (world units)
---@field width integer canvas width in braille cells (the crop box)
---@field height integer canvas height in braille cells (the crop box)
---@field ref_height? integer viewport height in dots the FOV subtends. nil = the
---  canvas itself: the wrfm CLI / wireforge TUI semantics, where the printed
---  canvas *is* the screen. An in-buffer preview instead passes the editor
---  screen's dot height (image.nvim's model: the window crops, never rescales),
---  so the footprint is fixed by FOV + distance alone.
---@field fov_deg? number field of view in degrees (default `renderer.FOV_DEG`)

---@class WrfmRaster 一次光栅化的结果：绝对 cell 坐标下的 braille 位图
---@field cells integer[] 稠密点阵，下标 = (row - origin_row) * grid_w + (col - origin_col) + 1
---@field grid_w integer 含 bleed 扩张的水平格数
---@field grid_h integer 含 bleed 扩张的垂直行数
---@field origin_col integer cells 首格绝对列号（画布左上 cell = 绝对 (0, 0)）
---@field origin_row integer cells 首格绝对行号
---@field canvas_w integer 画布水平格数（裁剪框）
---@field canvas_h integer 画布垂直行数（裁剪框）
---@field px_w integer 画布 dot 宽 = canvas_w * 2
---@field px_h integer 画布 dot 高 = canvas_h * 4
---@field clip WrfmRect 含 bleed 的裁剪矩形（屏幕单位）
---@field occupied boolean false = 本帧无点
---@field min_col integer 实际画出的占用包围盒（绝对列，仅 occupied 时有意义）
---@field max_col integer
---@field min_row integer
---@field max_row integer

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

-- Dot indices are canvas-anchored: the reference rasterizer maps the canvas
-- rect [-px/2, px/2] onto dot indices [0, px-1], and `snap_to_dot` keeps that
-- mapping no matter how far the clip rect reaches, so a bleeding frame only
-- widens which dots survive -- it never rescales the projection.
local function dot_to_screen(dot, px)
  return -px / 2 + (dot * px) / (px - 1)
end

---Clip rect of a bled grid, in screen units: the outer edge of the outermost
---cell's far dots (a cell spans two dot columns and four dot rows).
---@param canvas_w integer
---@param canvas_h integer
---@param px_w integer
---@param px_h integer
---@param bleed WrfmBleed?
---@return WrfmRect
local function bleed_rect(canvas_w, canvas_h, px_w, px_h, bleed)
  local col0 = -(bleed and bleed.left or 0)
  local col1 = canvas_w - 1 + (bleed and bleed.right or 0)
  local row0 = -(bleed and bleed.top or 0)
  local row1 = canvas_h - 1 + (bleed and bleed.bottom or 0)
  return {
    left = dot_to_screen(2 * col0, px_w),
    right = dot_to_screen(2 * col1 + 1, px_w),
    -- +y is up, so screen top/bottom swap against dot row order.
    top = -dot_to_screen(4 * row0, px_h),
    bottom = -dot_to_screen(4 * row1 + 3, px_h),
  }
end

---@param clip WrfmRect
---@param px_w integer
---@param px_h integer
---@return integer? dx canvas-anchored dot column
---@return integer? dy canvas-anchored dot row
local function snap_to_dot(x, y, clip, px_w, px_h)
  if x < clip.left or x > clip.right or y < clip.bottom or y > clip.top then
    return nil
  end
  return round((x + px_w / 2) * (px_w - 1) / px_w), round((px_h / 2 - y) * (px_h - 1) / px_h)
end

-- Sentinel clip rect that admits every finite coordinate: used by the
-- footprint probe, which must not clip anything away.
local UNCLIPPED = {
  left = -math.huge,
  right = math.huge,
  top = math.huge,
  bottom = -math.huge,
}

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

---Set the dot's bit in the grid cell it belongs to, dropping dots outside the
---grid and growing the extent of what was actually drawn.
---@param raster WrfmRaster
---@param x integer canvas-anchored dot column (may be negative)
---@param y integer canvas-anchored dot row
local function paint_dot(raster, x, y)
  local col, row = math.floor(x / 2), math.floor(y / 4)
  local offset = (row - raster.origin_row) * raster.grid_w + (col - raster.origin_col)
  if offset < 0 or offset >= raster.grid_w * raster.grid_h then
    return
  end
  local cell = offset + 1
  if raster.cells[cell] == 0 then
    if not raster.occupied then
      raster.occupied = true
      raster.min_col, raster.max_col, raster.min_row, raster.max_row = col, col, row, row
    else
      raster.min_col = math.min(raster.min_col, col)
      raster.max_col = math.max(raster.max_col, col)
      raster.min_row = math.min(raster.min_row, row)
      raster.max_row = math.max(raster.max_row, row)
    end
  end
  raster.cells[cell] = set_bit(raster.cells[cell], (x % 2) + 2 * (y % 4))
end

---@param raster WrfmRaster
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
local function paint_segment(raster, x1, y1, x2, y2)
  local ax, ay, bx, by = clip_segment(x1, y1, x2, y2, raster.clip)
  if not ax then
    return
  end
  local dx1, dy1 = snap_to_dot(ax, ay, raster.clip, raster.px_w, raster.px_h)
  if not dx1 then
    return
  end
  local dx2, dy2 = snap_to_dot(bx, by, raster.clip, raster.px_w, raster.px_h)
  if not dx2 then
    return
  end
  walk_line(dx1, dy1, dx2, dy2, function(x, y)
    paint_dot(raster, x, y)
  end)
end

---Rasterize a wireframe into an absolute braille-cell grid. The projection is
---framed by `view.ref_height`, so an inline canvas is a window onto a render of
---fixed scale: `width` x `height` decide what is cropped away, never how big the
---art is. Absolute cell (0, 0) is the canvas' top-left cell, so a negative
---column or row is art reaching left of / above the canvas.
---@param model { vertices: WrfmVec3[], edges: WrfmEdge[] }
---@param view WrfmView
---@param options? WrfmRasterOptions
---@return WrfmRaster
function M.rasterize(model, view, options)
  local canvas_w, canvas_h = view.width, view.height
  local px_w, px_h = canvas_w * 2, canvas_h * 4
  local ref_h = view.ref_height or px_h
  local bleed = options and options.bleed
  local origin_col = -(bleed and bleed.left or 0)
  local origin_row = -(bleed and bleed.top or 0)
  local grid_w = canvas_w + (bleed and bleed.left or 0) + (bleed and bleed.right or 0)
  local grid_h = canvas_h + (bleed and bleed.top or 0) + (bleed and bleed.bottom or 0)
  ---@type WrfmRaster
  local raster = {
    cells = {},
    grid_w = grid_w,
    grid_h = grid_h,
    origin_col = origin_col,
    origin_row = origin_row,
    canvas_w = canvas_w,
    canvas_h = canvas_h,
    px_w = px_w,
    px_h = px_h,
    clip = bleed_rect(canvas_w, canvas_h, px_w, px_h, bleed),
    occupied = false,
    min_col = 0,
    max_col = -1,
    min_row = 0,
    max_row = -1,
  }
  for i = 1, grid_w * grid_h do
    raster.cells[i] = 0
  end
  local rot = view.rot or M.rotation(view.pitch, view.yaw)
  local xs, ys, visible = M.project(model.vertices, rot, view.dist, ref_h, view.fov_deg)
  for _, edge in ipairs(model.edges) do
    local a, b = edge[1] + 1, edge[2] + 1
    if visible[a] and visible[b] then
      paint_segment(raster, xs[a], ys[a], xs[b], ys[b])
    end
  end
  return raster
end

---The model's true display range: the footprint in absolute cells with nothing
---clipped away, i.e. what the rasterizer would paint given an unlimited grid.
---Edges at or behind the near plane are skipped exactly as the rasterizer
---skips them, and a straight edge spans the cell box of its two endpoints, so
---this is the box `overflow = "visible"` would bleed into.
---@param model { vertices: WrfmVec3[], edges: WrfmEdge[] }
---@param view WrfmView
---@return boolean occupied false = nothing lands on screen, so all extents below are meaningless
---@return integer min_col
---@return integer max_col
---@return integer min_row
---@return integer max_row
function M.footprint(model, view)
  local px_w, px_h = view.width * 2, view.height * 4
  local rot = view.rot or M.rotation(view.pitch, view.yaw)
  local xs, ys, visible =
    M.project(model.vertices, rot, view.dist, view.ref_height or px_h, view.fov_deg)
  local occupied = false
  local min_col, max_col, min_row, max_row = 0, -1, 0, -1
  local function extend(col, row)
    if not occupied then
      occupied = true
      min_col, max_col, min_row, max_row = col, col, row, row
      return
    end
    min_col = math.min(min_col, col)
    max_col = math.max(max_col, col)
    min_row = math.min(min_row, row)
    max_row = math.max(max_row, row)
  end
  for _, edge in ipairs(model.edges) do
    local a, b = edge[1] + 1, edge[2] + 1
    if visible[a] and visible[b] then
      local ax, ay = snap_to_dot(xs[a], ys[a], UNCLIPPED, px_w, px_h)
      local bx, by = snap_to_dot(xs[b], ys[b], UNCLIPPED, px_w, px_h)
      if ax and bx then
        extend(math.floor(math.min(ax, bx) / 2), math.floor(math.min(ay, by) / 4))
        extend(math.floor(math.max(ax, bx) / 2), math.floor(math.max(ay, by) / 4))
      end
    end
  end
  return occupied, min_col, max_col, min_row, max_row
end

---Lay a raster out as text lines: `grid_h` lines, right-trimmed (may be empty).
---Leading blank cells are kept, so a raster whose art starts right of its own
---column 0 still lines up with the cells it was measured in.
---@param raster WrfmRaster
---@return string[]
local function raster_lines(raster)
  local lines = {}
  for row = 0, raster.grid_h - 1 do
    local base = row * raster.grid_w
    local last = 0
    for col = raster.grid_w, 1, -1 do
      if raster.cells[base + col] > 0 then
        last = col
        break
      end
    end
    local cells = {}
    for col = 1, last do
      cells[col] = BRAILLE[raster.cells[base + col] + 1]
    end
    lines[row + 1] = table.concat(cells)
  end
  return lines
end

M.raster_lines = raster_lines

---Braille glyph for a raster cell bitmask (`0` yields the space the
---rasterizer itself uses for an empty cell). The overlay segmenter calls this
---so it never has to duplicate the Unicode dot-bit table.
---@param pattern integer bitmask in `0..255`
---@return string
function M.cell_char(pattern)
  return BRAILLE[(pattern or 0) + 1]
end

---Rasterize a wireframe into braille text lines: `view` holds `pitch`, `yaw`
-- (radians), `dist` (camera distance), and canvas size `width` x `height` in
-- character cells (each cell is a 2x4 dot grid). A live viewer passes `rot`
-- (3x3 matrix, see mat_mul) instead; pitch/yaw then only seed static frames.
---Frames are clipped to the canvas, so output stays byte-identical to the wrfm
---CLI and `view.height` lines always describe the whole canvas.
---@param model { vertices: WrfmVec3[], edges: WrfmEdge[] }
---@param view WrfmView
---@return string[] exactly `height` lines, right-trimmed (may be empty)
function M.render_frame(model, view)
  return raster_lines(M.rasterize(model, view))
end

return M
