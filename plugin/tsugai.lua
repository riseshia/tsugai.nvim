if vim.g.loaded_tsugai then
  return
end
vim.g.loaded_tsugai = true

-- Visual mappings go through `:<C-u>` so the '< and '> marks are set before the Lua runs.
local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { silent = true, desc = "tsugai: " .. desc })
end

map("n", "<Space>fa", function() require("tsugai.chat").ask() end, "ask in the chat")
map("x", "<Space>fa", ":<C-u>lua require('tsugai.chat').ask_selection()<CR>", "ask about the selection")
map("n", "<Space>ft", function() require("tsugai.chat").toggle() end, "toggle the chat window")
map("n", "<Space>fe", function() require("tsugai.edit").run() end, "generate code for @@ai templates")
map("x", "<Space>fe", ":<C-u>lua require('tsugai.edit').run_selection()<CR>", "propose an edit to the selection")
map("n", "<Space>fu", function() require("tsugai.command").undo() end, "undo the last proposed command")
