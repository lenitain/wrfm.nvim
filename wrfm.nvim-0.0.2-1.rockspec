local modrev, specrev = "0.0.2", "-1"

rockspec_format = "3.0"
package = "wrfm.nvim"
version = modrev .. specrev

description = {
  summary = "Braille wireframe viewer for Neovim.",
  detailed = "Render .wrfm 3D wireframe models inside Neovim using Unicode braille characters. Zero dependencies, works over ssh/tmux.",
  labels = { "neovim", "neovim-plugin", "wireframe", "3d" },
  homepage = "https://github.com/lenitain/wrfm.nvim",
  license = "MIT",
}

dependencies = {
  "lua >= 5.1",
}

test_dependencies = {
  "nlua",
  "busted",
  "luassert",
}

source = {
  url = "git+https://github.com/lenitain/wrfm.nvim.git",
  tag = "v0.0.2",
}

test = {
  type = "busted",
  platforms = {
    unix = {
      flags = {
        "--config-file=.busted",
      },
    },
  },
}

build = {
  type = "builtin",
  copy_directories = {
    "doc",
    "ftdetect",
    "plugin",
  },
}
