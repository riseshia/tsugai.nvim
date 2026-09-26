local M = {}

local ns = vim.api.nvim_create_namespace("tsugai_card")
local MAX_WIDTH = 80

-- Opens a focused float for a proposal: `lines` with the first line emphasized and the last
-- one (the key hint) dimmed. `keys` maps a key to a handler that receives `close`; q and
-- <Esc> close the card unless `keys` takes them, and so does leaving it.
function M.open(title, lines, keys)
  local width = vim.fn.strdisplaywidth(" " .. title .. " ")
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, MAX_WIDTH, vim.o.columns - 4)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines) / 3),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = math.min(#lines, vim.o.lines - 4),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  -- Long lines wrap inside the width limit, so size the card by its wrapped height.
  local height = math.min(vim.api.nvim_win_text_height(win, {}).all, vim.o.lines - 4)
  vim.api.nvim_win_set_config(win, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 3),
    col = math.floor((vim.o.columns - width) / 2),
    height = height,
  })
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = "Statement" })
  vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, { line_hl_group = "Comment" })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
  for lhs, handler in pairs(keys) do
    vim.keymap.set("n", lhs, function() handler(close) end, opts)
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

return M
