local selection = require("tsugai.selection")
local sidecar = require("tsugai.sidecar")

local M = {}

-- width: what the user last resized the window to, reused when it opens again.
local state = { buf = nil, win = nil, width = nil }

function M.window()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return state.win
  end
end

local function buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.buf, "tsugai://chat")
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "# tsugai chat", "" })
  return state.buf
end

-- Opens the chat on the right without taking focus: the code window stays where the user types.
local function open()
  if M.window() then
    return
  end
  local width = state.width or math.floor(vim.o.columns * 0.35)
  state.win = vim.api.nvim_open_win(buffer(), false, { split = "right", win = -1, width = width })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function(args)
      state.width = vim.api.nvim_win_get_width(tonumber(args.match))
    end,
  })
  vim.wo[state.win].wrap = true
  vim.wo[state.win].linebreak = true
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
end

local function scroll()
  if M.window() then
    vim.api.nvim_win_set_cursor(state.win, { vim.api.nvim_buf_line_count(state.buf), 0 })
  end
  vim.cmd.redraw()
end

local function append_lines(lines)
  vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, lines)
  scroll()
end

local function append_text(text)
  local last = vim.api.nvim_buf_line_count(state.buf)
  local chunks = vim.split(text, "\n", { plain = true })
  chunks[1] = vim.api.nvim_buf_get_lines(state.buf, last - 1, last, false)[1] .. chunks[1]
  vim.api.nvim_buf_set_lines(state.buf, last - 1, last, false, chunks)
  scroll()
end

-- Tool calls go on their own lines, set apart from the streamed answer.
local function append_tool_line(line)
  local last = vim.api.nvim_buf_get_lines(state.buf, -2, -1, false)[1]
  vim.api.nvim_buf_set_lines(state.buf, last == "" and -2 or -1, -1, false, { line, "" })
  scroll()
end

-- The tool name arrives first and its input later, so the input is appended to the name's line.
local function on_progress(event)
  if event.tool then
    append_tool_line("`▸ " .. event.tool .. "`")
  elseif event.input then
    local row = vim.api.nvim_buf_line_count(state.buf) - 2
    local line = vim.api.nvim_buf_get_lines(state.buf, row, row + 1, false)[1]
    if line:match("^`▸ %S+`$") then
      vim.api.nvim_buf_set_lines(state.buf, row, row + 1, false, { line:sub(1, -2) .. " " .. event.input .. "`" })
    end
  else
    append_text(event.text)
  end
end

local function ask(selected)
  local question = vim.fn.input("tsugai ask> ")
  if question == "" then
    return
  end
  vim.cmd.echo([[""]])

  open()
  local header = { "", "## You", "", question }
  if selected then
    local where = ("_%s:%d-%d_"):format(vim.fn.fnamemodify(selected.path, ":~:."), selected.start_line, selected.end_line)
    table.insert(header, where)
  end
  vim.list_extend(header, { "", "## Claude", "", "" })
  append_lines(header)

  local ok, result = pcall(sidecar.request, "ask", { question = question, selection = selected }, on_progress)
  if not ok then
    return append_tool_line("_" .. result .. "_")
  end
  if result.command then
    require("tsugai.command").propose(result.command)
  end
end

function M.ask()
  ask(nil)
end

-- Called after leaving visual mode, so the '< and '> marks hold the selection.
function M.ask_selection()
  ask(selection.get(vim.api.nvim_get_current_buf()))
end

function M.toggle()
  if M.window() then
    vim.api.nvim_win_close(state.win, false)
  else
    open()
  end
end

return M
