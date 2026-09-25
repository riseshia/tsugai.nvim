local M = {}

M.config = {
  -- Free-form preferences appended to Claude's system prompt, e.g. "Answer in Korean."
  instructions = "",
  -- Every tsugai key starts with this, e.g. <Space>fe.
  prefix = "<Space>f",
}

function M.key(suffix)
  return M.config.prefix .. suffix
end

-- { mode, lhs } of the global mappings, so a new prefix can replace them.
local mapped = {}

function M.map_keys()
  for _, m in ipairs(mapped) do
    pcall(vim.keymap.del, m[1], m[2])
  end
  mapped = {}

  -- Visual mappings go through `:<C-u>` so the '< and '> marks are set before the Lua runs.
  local function map(mode, suffix, rhs, desc)
    vim.keymap.set(mode, M.key(suffix), rhs, { silent = true, desc = "tsugai: " .. desc })
    table.insert(mapped, { mode, M.key(suffix) })
  end
  map("n", "a", function() require("tsugai.chat").ask() end, "ask in the chat")
  map("x", "a", ":<C-u>lua require('tsugai.chat').ask_selection()<CR>", "ask about the selection")
  map("n", "t", function() require("tsugai.chat").toggle() end, "toggle the chat window")
  map("n", "e", function() require("tsugai.edit").run() end, "generate code for @@ai templates")
  map("x", "e", ":<C-u>lua require('tsugai.edit').run_selection()<CR>", "propose an edit to the selection")
  map("n", "u", function() require("tsugai.command").undo() end, "undo the last proposed command")
end

-- instructions take effect when the sidecar starts, which happens on the first request.
function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})
  M.map_keys()
end

return M
