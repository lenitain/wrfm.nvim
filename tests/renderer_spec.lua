-- Renderer math and frame-geometry tests, absorbed from the original unit checks.
local renderer = require("wrfm.renderer")
local helpers = require("helpers")

local HALF_TAN = math.tan(math.rad(30))

local cube_vertices = {
  { -1, -1, -1 },
  { 1, -1, -1 },
  { 1, 1, -1 },
  { -1, 1, -1 },
  { -1, -1, 1 },
  { 1, -1, 1 },
  { 1, 1, 1 },
  { -1, 1, 1 },
}
local cube_edges = {
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
}

describe("renderer", function()
  it("angle + fit", function()
    assert.is.near(4 - 2 * math.pi, renderer.normalize_angle(4), 1e-9, "normalize_angle wraps >pi")
    assert.is.near(
      -4 + 2 * math.pi,
      renderer.normalize_angle(-4),
      1e-9,
      "normalize_angle wraps <pi"
    )
    for _, angle in ipairs({ 0, 1.5, -1.5, 20.44, -20.44 }) do
      local wrapped = renderer.normalize_angle(angle)
      assert.is_true(
        wrapped >= -math.pi and wrapped <= math.pi,
        ("normalize_angle range (%s)"):format(angle)
      )
    end

    assert.is.near(
      2 / HALF_TAN * 2,
      renderer.fit_distance(cube_vertices),
      1e-9,
      "fit_distance matches extent/tan(30)*2"
    )
    local long_dist = renderer.fit_distance({ { 0, 0, 0 }, { 6, 4, 160 } })
    assert.is_true(
      long_dist > 10 and long_dist < 100,
      ("long-axis fit not dominated by the 160 axis (dist=%s)"):format(long_dist)
    )
    assert.are.equal(8, renderer.fit_distance({}), "empty model falls back to default distance")
  end)

  it("frame geometry", function()
    local lines = renderer.render_frame({ vertices = cube_vertices, edges = cube_edges }, {
      pitch = math.rad(30),
      yaw = math.rad(45),
      dist = renderer.fit_distance(cube_vertices),
      width = 41,
      height = 21,
    })
    assert.are.equal(21, #lines, "frame has one line per canvas row")

    local min_col, max_col, min_row, max_row = math.huge, -math.huge, math.huge, -math.huge
    for row, line in ipairs(lines) do
      if line ~= "" then
        min_col = math.min(min_col, #line:match("^ *") + 1)
        max_col = math.max(max_col, vim.fn.strchars(line))
        min_row = math.min(min_row, row)
        max_row = math.max(max_row, row)
      end
    end
    assert.is_true(
      math.abs((min_col + max_col) / 2 - 21) <= 2,
      ("cube horizontally centred (col centre %.1f)"):format((min_col + max_col) / 2)
    )
    assert.is_true(
      math.abs((min_row + max_row) / 2 - 11) <= 2,
      ("cube vertically centred (row centre %.1f)"):format((min_row + max_row) / 2)
    )

    local expected_origin_text = "     \xe2\xa0\x81"
    for _, view in ipairs({ { 0, 0 }, { 30, 45 }, { -89, 200 }, { 120, -359 } }) do
      local dot_frame = renderer.render_frame(
        { vertices = { { 0, 0, 0 }, { 0, 0, 0 } }, edges = { { 0, 1 } } },
        { pitch = math.rad(view[1]), yaw = math.rad(view[2]), dist = 8, width = 10, height = 6 }
      )
      local rendered = {}
      for row, line in ipairs(dot_frame) do
        if line ~= "" then
          rendered[#rendered + 1] = ("%d:%s"):format(row, line)
        end
      end
      assert.are.same(
        { ("4:%s"):format(expected_origin_text) },
        rendered,
        ("origin dot at canvas centre for pitch=%s yaw=%s"):format(view[1], view[2])
      )
    end

    local far_cube = {}
    for i, v in ipairs(cube_vertices) do
      far_cube[i] = { v[1], v[2], v[3] + 6 }
    end
    local behind = renderer.render_frame(
      { vertices = far_cube, edges = cube_edges },
      { pitch = 0, yaw = 0, dist = 1, width = 10, height = 4 }
    )
    assert.are.equal(4, #behind, "behind-camera frame keeps row count")
    local blank = true
    for _, line in ipairs(behind) do
      if line ~= "" then
        blank = false
      end
    end
    assert.is_true(blank, "fully occluded model yields a blank frame")

    local point_frame = renderer.render_frame(
      { vertices = { { 0, 0, 0 }, { 0, 0, 0 } }, edges = { { 0, 1 } } },
      { pitch = 0, yaw = 0, dist = 8, width = 9, height = 5 }
    )
    local painted = {}
    for row_idx, line in ipairs(point_frame) do
      if line ~= "" then
        painted[#painted + 1] = ("%d:%s"):format(row_idx, line)
      end
    end
    assert.are.same({ "3:    \xe2\xa0\xa0" }, painted, "degenerate edge paints one dot")
  end)

  it("programmatic fixture renders", function()
    local spec = helpers.fixture_cube()
    local data = { vertices = spec.vertices, edges = spec.edges }
    local lines = renderer.render_frame(data, {
      pitch = math.rad(30),
      yaw = math.rad(45),
      dist = renderer.fit_distance(data.vertices),
      width = 40,
      height = 12,
    })
    assert.are.equal(12, #lines, "fixture cube renders at expected height")
    local non_empty = 0
    for _, line in ipairs(lines) do
      if line ~= "" then
        non_empty = non_empty + 1
      end
    end
    assert.is_true(non_empty > 0, "fixture cube produces visible output")
  end)
end)
