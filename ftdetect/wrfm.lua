-- .wrfm wireframe models: gives buffers a real filetype so the FileType
-- autocmd behind integrations.wrfm can auto-attach the inline preview.
vim.filetype.add({
  extension = {
    wrfm = "wrfm",
  },
})
