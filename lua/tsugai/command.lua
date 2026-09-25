local M = {}

local ns = vim.api.nvim_create_namespace("tsugai_command")

-- Commands that take the rest of the line as another command.
local ITERATORS = { cfdo = true, cdo = true, lfdo = true, ldo = true, bufdo = true, argdo = true, windo = true, tabdo = true }
-- Commands that change text but cannot reach the shell or evaluate code.
local ALLOWED = {
  s = true, substitute = true, ["&"] = true, ["&&"] = true, ["~"] = true,
  d = true, delete = true, m = true, move = true, t = true, co = true, copy = true,
  j = true, join = true, [">"] = true, ["<"] = true, sort = true, retab = true,
  le = true, left = true, ri = true, right = true, ce = true, center = true,
  norm = true, normal = true, noh = true, nohlsearch = true,
}
local GLOBALS = { g = true, global = true, v = true, vglobal = true }

-- Splits off the command name after a range such as `%`, `'<,'>` or `1,$`.
local function head(cmd)
  local rest = cmd:gsub("^[%s:]*", ""):gsub("^[%%%.%$%d,;%+%-]*", ""):gsub("^'[%a<>]", ""):gsub("^[,;]'[%a<>]", "")
  local name = rest:match("^%a+") or rest:match("^[&~<>]+")
  if not name then
    return nil, rest
  end
  return name, rest:sub(#name + 1)
end

local function check_one(cmd)
  if cmd:match("^%s*$") then
    return nil
  end
  local name, rest = head(cmd)
  if not name then
    return "cannot tell which command `" .. cmd .. "` runs"
  end
  if ITERATORS[name] then
    return check_one(rest)
  end
  if GLOBALS[name] then
    -- :g/pattern/command — the command after the closing delimiter is checked in turn.
    local delim = rest:sub(1, 1)
    local close = rest:find(delim, 2, true)
    while close and rest:sub(close - 1, close - 1) == "\\" do
      close = rest:find(delim, close + 1, true)
    end
    return close and check_one(rest:sub(close + 1)) or nil
  end
  if not ALLOWED[name] then
    return "`" .. name .. "` is not an allowed command"
  end
  -- `|` ends a substitute and starts another command; normal takes the rest as keys.
  if name ~= "norm" and name ~= "normal" then
    local bar = rest:find("[^\\]|")
    if bar then
      return check_one(rest:sub(bar + 2))
    end
  end
  return nil
end

-- Returns why `cmd` may not run, or nil. `!` can reach the shell (`:!`, filters, `normal !!`)
-- and `\=` evaluates an expression that could call system(), so both are refused outright
-- rather than parsed.
function M.check(cmd)
  if cmd:find("!", 1, true) then
    return "`!` is not allowed"
  end
  if cmd:find("\\=", 1, true) then
    return "`\\=` expressions are not allowed"
  end
  return check_one(cmd)
end

local last_run

-- Undo sequence numbers of loaded buffers, so a whole run can be undone; buffers loaded
-- by the command itself start from 0.
local function undo_points()
  local points = {}
  for _, info in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
    points[info.bufnr] = vim.api.nvim_buf_call(info.bufnr, function()
      return vim.fn.undotree().seq_cur
    end)
  end
  return points
end

local function execute(proposal)
  local before = undo_points()
  local ok, err = pcall(vim.cmd, proposal.command)
  local changed = {}
  for bufnr, seq in pairs(undo_points()) do
    if seq ~= (before[bufnr] or 0) then
      changed[bufnr] = before[bufnr] or 0
    end
  end
  last_run = changed
  if not ok then
    return vim.notify("tsugai: " .. tostring(err), vim.log.levels.ERROR)
  end
  local count = vim.tbl_count(changed)
  vim.notify(("tsugai: changed %d buffer(s). :wa to save, <Space>fu to undo"):format(count))
end

function M.undo()
  if not last_run then
    return vim.notify("tsugai: nothing to undo", vim.log.levels.WARN)
  end
  for bufnr, seq in pairs(last_run) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent undo " .. seq)
      end)
    end
  end
  vim.notify(("tsugai: undid the command in %d buffer(s)"):format(vim.tbl_count(last_run)))
  last_run = nil
end

local function fill_quickfix(proposal)
  if #proposal.locations == 0 then
    return
  end
  local items = vim.tbl_map(function(loc)
    return { filename = loc.path, lnum = loc.line, text = loc.text }
  end, proposal.locations)
  vim.fn.setqflist({}, " ", { title = "tsugai: " .. proposal.title, items = items })
  local win = vim.api.nvim_get_current_win()
  vim.cmd("botright copen")
  vim.api.nvim_set_current_win(win)
end

local function card_lines(proposal)
  local lines = { ":" .. proposal.command, "" }
  local width = 0
  for _, part in ipairs(proposal.explanation) do
    width = math.max(width, vim.fn.strdisplaywidth(part.token))
  end
  for _, part in ipairs(proposal.explanation) do
    local pad = string.rep(" ", width - vim.fn.strdisplaywidth(part.token))
    table.insert(lines, "  " .. part.token .. pad .. "  " .. part.meaning)
  end
  if #proposal.locations > 0 then
    local files = {}
    for _, loc in ipairs(proposal.locations) do
      files[loc.path] = true
    end
    vim.list_extend(lines, { "", ("  %d location(s) in %d file(s), listed in quickfix"):format(#proposal.locations, vim.tbl_count(files)) })
  end
  vim.list_extend(lines, { "", "<CR> run   e edit in cmdline   q cancel" })
  return lines
end

local function show_card(proposal)
  local lines = card_lines(proposal)
  local width = vim.fn.strdisplaywidth(" " .. proposal.title .. " ")
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 4)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines) / 3),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " " .. proposal.title .. " ",
  })
  vim.wo[win].wrap = true
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = "Statement" })
  vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, { line_hl_group = "Comment" })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    close()
    execute(proposal)
  end, opts)
  vim.keymap.set("n", "e", function()
    close()
    vim.api.nvim_feedkeys(":" .. proposal.command, "n", false)
  end, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

-- Shows a command Claude proposed from the chat. Checked again here: this is what actually
-- runs, whatever the sidecar let through.
function M.propose(proposal)
  local problem = M.check(proposal.command)
  if problem then
    return vim.notify("tsugai: refused to show the command: " .. problem, vim.log.levels.ERROR)
  end
  fill_quickfix(proposal)
  show_card(proposal)
end

return M
