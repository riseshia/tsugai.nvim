-- Minimal config for recording the README GIFs: this checkout plus plain Neovim.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)

vim.o.number = true
vim.o.termguicolors = true
vim.o.laststatus = 2
vim.o.shortmess = vim.o.shortmess .. "I"
vim.cmd.colorscheme("habamax")

-- The README is in English, whatever language the recording machine's Claude settings lean to.
require("tsugai").setup({ instructions = "Always answer in English." })
