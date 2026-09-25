local M = {}

local HEIGHT = 12
local state = { buf = nil, win = nil }

local function width()
  return math.min(80, math.floor(vim.o.columns * 0.5))
end

function M.open(title)
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "waiting for Claude…", "" })
  state.win = vim.api.nvim_open_win(state.buf, false, {
    relative = "editor",
    row = vim.o.lines - HEIGHT - 4,
    col = vim.o.columns - width() - 2,
    width = width(),
    height = HEIGHT,
    style = "minimal",
    border = "rounded",
    title = " tsugai: " .. title .. " (<C-c> to cancel) ",
  })
  vim.wo[state.win].wrap = true
  -- The editor blocks until the reply, so nothing redraws unless forced.
  vim.cmd.redraw()
end

local function append_text(text)
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local chunks = vim.split(text, "\n", { plain = true })
  lines[#lines] = lines[#lines] .. chunks[1]
  for i = 2, #chunks do
    table.insert(lines, chunks[i])
  end
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
end

local function append_line(line)
  -- Keep a trailing empty line for streamed text to append to, without clobbering text already there.
  local last = vim.api.nvim_buf_get_lines(state.buf, -2, -1, false)[1]
  vim.api.nvim_buf_set_lines(state.buf, last == "" and -2 or -1, -1, false, { line, "" })
end

function M.append(event)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end

  if event.tool then
    append_line("▸ " .. event.tool)
  elseif event.input then
    append_line("  " .. event.input)
  else
    append_text(event.text)
  end
  vim.api.nvim_win_set_cursor(state.win, { vim.api.nvim_buf_line_count(state.buf), 0 })
  vim.cmd.redraw()
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win, state.buf = nil, nil
end

return M
