-- Parser tests, absorbed from the original /tmp unit checks.
local parser = require("wrfm.parser")

describe("parser", function()
  it("happy path", function()
    local cube = parser.parse([[
# a unit box
wrfm 1
vertices 10   edges 12   # counts include the group re-listed vertices

v 0 0 0
v 1 0 0
v 1 0 1
v 0 0 1
v 0 1 0    v 1 1 0
v 1 1 1
v 0 1 1

group base
v 0 0 0
v 1 0 0
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
    assert.are.same(
      { 10, 12 },
      { #cube.vertices, #cube.edges },
      "cube parses with group sections present"
    )
    assert.are.equal(1.0, cube.vertices[6][2], "group re-listed vertices keep global file order")
    assert.are.equal(1, #cube.groups, "one group recorded")
    assert.are.equal("base", cube.groups[1].name, "group name captured")
    assert.are.equal(13, cube.groups[1].start_line, "group line number is 1-based physical line")

    local packed = parser.parse("wrfm 1 vertices 2 edges 1 v 0 0 0 v 3 3 3 e 1 0")
    assert.are.equal(2, #packed.vertices, "elements may pack several per line")
    assert.are.equal(0, #packed.groups, "no groups yields empty table")
  end)

  it("programmatic fixture", function()
    local helpers = require("helpers")
    local text = helpers.fixture(helpers.fixture_cube())
    local data = parser.parse(text)
    assert.are.equal(8, #data.vertices, "fixture cube has 8 vertices")
    assert.are.equal(12, #data.edges, "fixture cube has 12 edges")
  end)

  it("rejections", function()
    assert.has_error(function()
      parser.parse("wrms 1\nvertices 0 edges 0")
    end, "expected magic line 'wrfm 1', got 'wrms'")
    assert.has_error(function()
      parser.parse("")
    end, "wrfm: empty model file")
    assert.has_error(function()
      parser.parse("wrfm 1\nvertices 1 edges 0")
    end, "wrfm: counts mismatch: declared vertices 1 edges 0, found 0 and 0")
    assert.has_error(function()
      parser.parse("wrfm 1\nvertices 2 edges 1\nv 0 0 0\ne 0 1")
    end, "wrfm: counts mismatch: declared vertices 2 edges 1, found 1 and 1")
    assert.has_error(function()
      parser.parse("wrfm 1\nvertices 2 edges 1\nv 0 0 0\nv 0 0 0\ne 0 5")
    end, "wrfm: edge 0 references out-of-range vertex 5")
    assert.has_error(function()
      parser.parse("wrfm 1\nvertices 2 edges 1\nv 0 0 0\nv 0 0 0\ne 0 1.5")
    end, "edge index must be a non-negative integer, got '1.5'")
    assert.has_error(function()
      parser.parse("wrfm 1\nvertices 1 edges 0\nv nan 0 0")
    end, "invalid vertex x 'nan'")
    assert.has_error(function()
      parser.parse("wrfm 1\nvertices 1 edges 0\nv inf 0 0")
    end, "invalid vertex x 'inf'")
    assert.has_error(function()
      parser.parse("wrfm 1\nvertices 1 edges 0\nx 0 0 0")
    end, "unexpected element 'x'")
    assert.has_error(function()
      parser.parse("wrfm 1")
    end, "wrfm: missing counts 'vertices <N> edges <M>'")
  end)
end)
