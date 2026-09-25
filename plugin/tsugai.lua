if vim.g.loaded_tsugai then
  return
end
vim.g.loaded_tsugai = true

vim.keymap.set("x", "<Space>ae", ":<C-u>lua require('tsugai.edit').run()<CR>", {
  silent = true,
  desc = "tsugai: propose an edit to the selection",
})
