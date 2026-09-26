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
  -- Vim's markdown syntax marks `_` inside a word as an error, which paints every snake_case name.
  vim.api.nvim_buf_call(state.buf, function()
    vim.cmd("silent! syntax clear markdownError")
  end)
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

-- Sends a request with a live "working" line in the chat's winbar: chat requests show their
-- progress in the chat instead of the progress float, which is where the cancel hint was.
local function request(method, params)
  local started = vim.uv.hrtime()
  local function show_status()
    if M.window() then
      local seconds = math.floor((vim.uv.hrtime() - started) / 1e9)
      vim.wo[state.win].winbar = ("%%#WarningMsg# ⏳ Claude is working · %ds · <C-c> to cancel"):format(seconds)
      vim.cmd.redraw()
    end
  end
  show_status()
  local timer = vim.uv.new_timer()
  timer:start(1000, 1000, vim.schedule_wrap(show_status))
  local ok, result = pcall(sidecar.request, method, params, on_progress)
  timer:stop()
  timer:close()
  if M.window() then
    vim.wo[state.win].winbar = ""
  end
  return ok, result
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

  -- The buffer the user was looking at; proposals without a path belong to it.
  local code_bufnr = vim.api.nvim_get_current_buf()
  local ok, result = request("ask", { question = question, selection = selected })
  if not ok then
    return append_tool_line("_" .. result .. "_")
  end
  if result.hunks then
    local shown, missing = require("tsugai.diff").show_across(result.hunks, code_bufnr)
    local note = ("_%d proposal(s), listed in the quickfix list_"):format(shown)
    if missing > 0 then
      note = note .. (" _(%d did not match their file and were dropped)_"):format(missing)
    end
    append_tool_line(note)
  end
  if result.command then
    require("tsugai.command").propose(result.command)
  end
  if result.plan then
    require("tsugai.plan").propose(result.plan)
  end
end

-- An italic line in the chat, for things tsugai itself reports.
function M.note(text)
  open()
  append_tool_line("_" .. text .. "_")
end

-- Has Claude carry out an accepted plan. Its edits land on disk, so open buffers are
-- reloaded afterwards and the changed files are listed for review.
function M.execute_plan(plan)
  open()
  append_lines({ "", "## Claude: " .. plan.title, "", "" })
  local ok, result = request("execute", { plan = plan })
  vim.cmd("checktime")
  if not ok then
    return append_tool_line("_" .. result .. " (files changed so far stay changed; see git diff)_")
  end
  if #result.changed == 0 then
    return append_tool_line("_No files were changed._")
  end
  local items = vim.tbl_map(function(path)
    return { filename = path, lnum = 1, text = "changed by: " .. plan.title }
  end, result.changed)
  vim.fn.setqflist({}, " ", { title = "tsugai: " .. plan.title, items = items })
  local win = vim.api.nvim_get_current_win()
  vim.cmd("botright copen")
  vim.api.nvim_set_current_win(win)
  append_tool_line(("_%d file(s) changed, listed in the quickfix list. Review with git diff._"):format(#result.changed))
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
