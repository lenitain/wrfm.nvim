-- Oracle regression: our Lua renderer must stay byte-identical to frames
-- produced by the `wrfm` CLI (same rasterizer as the wireforge TUI).
-- Golden frames live in tests/fixtures/golden; regeneration is `mise run golden`.
local parser = require("wrfm.parser")
local renderer = require("wrfm.renderer")
local helpers = require("helpers")

local uv = vim.uv or vim.loop

local function parse_golden_name(name)
  local model, pitch, yaw, w, h = name:match("^(.+)%-(%-?%d+)%-(%-?%d+)%-(%d+)x(%d+)%.txt$")
  if not model then
    return nil
  end
  return {
    model = model,
    pitch = tonumber(pitch),
    yaw = tonumber(yaw),
    width = tonumber(w),
    height = tonumber(h),
  }
end

local function golden_rows(text, height)
  local rows = {}
  local body = text:gsub("\n$", "")
  for line in (body .. "\n"):gmatch("(.-)\n") do
    if line:sub(1, 1) ~= "#" then
      rows[#rows + 1] = (line:gsub("%s+$", ""))
    end
  end
  while #rows < height do
    rows[#rows + 1] = ""
  end
  return rows
end

local function our_rows(data, pitch, yaw, w, h)
  return renderer.render_frame(data, {
    pitch = math.rad(pitch),
    yaw = math.rad(yaw),
    dist = renderer.fit_distance(data.vertices),
    width = w,
    height = h,
  })
end

describe("oracle", function()
  it("golden fixtures", function()
    if os.getenv("WRFM_SKIP_ORACLE") == "1" then
      pending("WRFM_SKIP_ORACLE=1")
      return
    end
    local golden_dir = helpers.repo_dir() .. "/tests/fixtures/golden"
    local scandir = uv.fs_scandir(golden_dir)
    if not scandir then
      pending("no golden fixtures directory (run: mise run golden)")
      return
    end
    local names = {}
    while true do
      local name, kind = uv.fs_scandir_next(scandir)
      if not name then
        break
      end
      if kind == "file" and name:match("%.txt$") then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    assert.is_true(#names > 0, "golden directory holds fixture files")
    if #names == 0 then
      return
    end

    local parsed_cache = {}
    for _, name in ipairs(names) do
      local params = parse_golden_name(name)
      assert.is_truthy(params, ("filename encodes parameters: %s"):format(name))
      if params then
        if not parsed_cache[params.model] then
          local path = helpers.fixture_model(params.model)
          local text = helpers.read_file(path)
          if not text then
            pending(("model fixture missing for %s"):format(name))
            parsed_cache[params.model] = false
          else
            local ok, data = pcall(parser.parse, text)
            if not ok then
              assert.is_truthy(false, ("model fixture parses: %s"):format(params.model))
              parsed_cache[params.model] = false
            else
              parsed_cache[params.model] = data
            end
          end
        end
        local data = parsed_cache[params.model]
        if data then
          local expected = golden_rows(helpers.read_file(golden_dir .. "/" .. name), params.height)
          local got = our_rows(data, params.pitch, params.yaw, params.width, params.height)
          local mismatch = nil
          if #got ~= #expected then
            mismatch = ("row count %d, expected %d"):format(#got, #expected)
          else
            for i = 1, #expected do
              if got[i] ~= expected[i] then
                mismatch = ("row %d:\n    expected: %q\n    got:      %q"):format(
                  i,
                  expected[i],
                  got[i]
                )
                break
              end
            end
          end
          assert.is_nil(
            mismatch,
            ("%s pitch=%d yaw=%d %dx%d byte-identical"):format(
              params.model,
              params.pitch,
              params.yaw,
              params.width,
              params.height
            )
          )
          if mismatch then
            print(("    oracle diff for %s:\n    %s"):format(name, mismatch))
          end
        end
      end
    end
  end)

  it("live CLI (opt-in)", function()
    local dir = os.getenv("WRFM_ORACLE_MODELS")
    if not dir or dir == "" then
      pending("set WRFM_ORACLE_MODELS=<dir of .wrfm files> to enable")
      return
    end
    if vim.fn.executable("wrfm") ~= 1 then
      pending("wrfm CLI not on PATH")
      return
    end
    local views = { { 30, 45 }, { 0, 0 }, { 90, 0 } }
    local sizes = { { 40, 12 }, { 17, 7 } }
    local scandir = uv.fs_scandir(vim.fs.normalize(dir))
    while true do
      local name = uv.fs_scandir_next(scandir)
      if not name then
        break
      end
      if name:match("%.wrfm$") then
        local path = vim.fs.normalize(dir) .. "/" .. name
        local ok, data = pcall(parser.parse, helpers.read_file(path))
        if not ok then
          pending(("skipping unparseable %s"):format(name))
        else
          for _, view in ipairs(views) do
            for _, size in ipairs(sizes) do
              local res = vim
                .system({
                  "wrfm",
                  "render",
                  path,
                  "--format",
                  "braille",
                  "--views=",
                  "--pitch=" .. view[1],
                  "--yaw=" .. view[2],
                  "--width=" .. size[1],
                  "--height=" .. size[2],
                }, { text = true })
                :wait()
              local expected = {}
              if res.code == 0 then
                local body = res.stdout:gsub("\n$", "")
                for line in (body .. "\n"):gmatch("(.-)\n") do
                  if line:sub(1, 1) ~= "#" then
                    expected[#expected + 1] = (line:gsub("%s+$", ""))
                  end
                end
                while #expected < size[2] do
                  expected[#expected + 1] = ""
                end
              end
              assert.are.equal(
                expected,
                our_rows(data, view[1], view[2], size[1], size[2]),
                ("%s p%d y%d %dx%d matches live CLI"):format(
                  name,
                  view[1],
                  view[2],
                  size[1],
                  size[2]
                )
              )
            end
          end
        end
      end
    end
  end)
end)
