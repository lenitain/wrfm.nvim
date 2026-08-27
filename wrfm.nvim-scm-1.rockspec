local modrev, specrev = "scm", "-1"

rockspec_format = "3.0"
package = "wrfm.nvim"
version = modrev .. specrev

description = {
  summary = "Braille wireframe viewer for Neovim.",
  detailed = "Render .wrfm 3D wireframe models inside Neovim using Unicode braille characters. Zero dependencies, works over ssh/tmux.",
  labels = { "neovim", "neovim-plugin", "wireframe", "3d" },
  homepage = "https://github.com/you/wrfm.nvim",
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
  url = "git://github.com/you/wrfm.nvim",
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
