-- .wrfm wireframe models: gives buffers a real filetype so `:WrfmHere` — and
-- the opt-in FileType hook behind integrations.wrfm — can recognise a model
-- source buffer. Nothing renders on the strength of this filetype alone.
vim.filetype.add({
  extension = {
    wrfm = "wrfm",
  },
})
