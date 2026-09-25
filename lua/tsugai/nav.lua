local M = {}

-- The window the user edits code in: never the chat window.
local function code_window()
  local chat = require("tsugai.chat").window()
  local current = vim.api.nvim_get_current_win()
  if current ~= chat then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= chat and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

-- Called by the sidecar's open_file tool. Returns true, or a message saying why not.
function M.open(path, line)
  if vim.fn.filereadable(path) == 0 and vim.fn.bufexists(path) == 0 then
    return "no such file: " .. path
  end
  local win = code_window()
  if not win then
    return "no editor window to open it in"
  end
  local ok, err = pcall(vim.api.nvim_win_call, win, function()
    vim.cmd.edit(vim.fn.fnameescape(path))
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(line, last), 0 })
    vim.cmd("normal! zz")
  end)
  vim.cmd.redraw()
  return ok or tostring(err)
end

return M
