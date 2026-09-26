local M = {}

local ns = vim.api.nvim_create_namespace("tsugai_diff")

vim.api.nvim_set_hl(0, "TsugaiGhost", { default = true, fg = "#808080", ctermfg = 244 })
-- Red as well as strikethrough: terminals such as screen-256color cannot draw strikethrough.
vim.api.nvim_set_hl(0, "TsugaiRemoved", { default = true, strikethrough = true, fg = "#e06c75", ctermfg = 167 })
vim.api.nvim_set_hl(0, "TsugaiHint", { default = true, link = "Comment" })

local key = require("tsugai").key

local function hint()
  return ("%s accept · %s reject · %s refine"):format(key("y"), key("n"), key("r"))
end

-- bufnr -> list of { anchor, marks, old_text, new_lines, reason }
local reviews = {}

local function split(text)
  if text == "" then
    return {}
  end
  return vim.split(text:gsub("\n$", ""), "\n", { plain = true })
end

local function rtrim(line)
  return (line:gsub("%s+$", ""))
end

-- Virtual text renders a tab as a single cell, so expand it to match the buffer's layout.
local function expand_tabs(bufnr, line)
  return (line:gsub("\t", string.rep(" ", vim.bo[bufnr].tabstop)))
end

-- Returns the 0-based row where `needle` starts, preferring the match closest to `near`.
local function locate(bufnr, needle, near)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local best
  for row = 0, #lines - #needle do
    local matched = true
    for i, line in ipairs(needle) do
      if rtrim(lines[row + i]) ~= rtrim(line) then
        matched = false
        break
      end
    end
    if matched and (not best or math.abs(row - near) < math.abs(best - near)) then
      best = row
    end
  end
  return best
end

local function range(bufnr, hunk)
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, hunk.anchor, { details = true })
  return mark[1], mark[3].end_row
end

-- Byte length of the common prefix, backed off to a UTF-8 character boundary.
local function common_prefix(a, b)
  local n = 0
  while n < #a and n < #b and a:byte(n + 1) == b:byte(n + 1) do
    n = n + 1
  end
  while n > 0 and n < #a and a:byte(n + 1) >= 0x80 and a:byte(n + 1) < 0xC0 do
    n = n - 1
  end
  return n
end

local function width(bufnr, text)
  return vim.fn.strdisplaywidth(expand_tabs(bufnr, text))
end

-- Marks stick to the start of their position. With the default gravity, replacing a whole
-- line (cc, a formatter, nvim_buf_set_lines) pushes a mark at column 0 onto the next line,
-- so the hunk's range would end before it starts.
local function mark(bufnr, row, col, opts)
  opts.right_gravity = false
  return vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, opts)
end

-- Like Copilot, only the part that changes is drawn as ghost text; unchanged code keeps its
-- own highlighting. conceal_lines can't hide the lines being replaced: concealing every line
-- of a buffer also hides the virtual lines attached to it.
local function render(bufnr, row, hunk)
  local old_lines = split(hunk.old_text)
  local last = row + #old_lines - 1
  local current = vim.api.nvim_buf_get_lines(bufnr, row, last + 1, false)
  local new_lines = hunk.new_lines

  local head = 0
  while head < #current and head < #new_lines and current[head + 1] == new_lines[head + 1] do
    head = head + 1
  end
  local tail = 0
  while tail < #current - head and tail < #new_lines - head and current[#current - tail] == new_lines[#new_lines - tail] do
    tail = tail + 1
  end

  local marks = {}
  local changed_old = #current - head - tail
  local changed_new = #new_lines - head - tail

  for i = 1, changed_old do
    local r = row + head + i - 1
    local old = current[head + i]
    local new = new_lines[head + i]
    if i > changed_new then
      table.insert(marks, mark(bufnr, r, 0, {
        end_row = r,
        end_col = #old,
        hl_group = "TsugaiRemoved",
      }))
    else
      local col = common_prefix(old, new)
      local text = expand_tabs(bufnr, new:sub(col + 1))
      local padding = math.max(0, width(bufnr, old) - width(bufnr, old:sub(1, col)) - vim.fn.strdisplaywidth(text))
      table.insert(marks, mark(bufnr, r, col, {
        virt_text = { { text .. string.rep(" ", padding), "TsugaiGhost" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
      }))
    end
  end

  if changed_new > changed_old then
    local extra = {}
    for i = head + changed_old + 1, head + changed_new do
      table.insert(extra, { { expand_tabs(bufnr, new_lines[i]), "TsugaiGhost" } })
    end
    local below = row + head + changed_old - 1
    if below >= row then
      table.insert(marks, mark(bufnr, below, 0, { virt_lines = extra }))
    else
      table.insert(marks, mark(bufnr, row, 0, { virt_lines = extra, virt_lines_above = true }))
    end
  end

  hunk.marks = marks
  hunk.anchor = mark(bufnr, row, 0, {
    end_row = last,
    end_col = #current[#current],
  })
end

local function clear(bufnr, hunk)
  vim.api.nvim_buf_del_extmark(bufnr, ns, hunk.anchor)
  for _, mark in ipairs(hunk.marks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns, mark)
  end
end

function M.hunk_at_cursor(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for i, hunk in ipairs(reviews[bufnr] or {}) do
    local first, last = range(bufnr, hunk)
    if row >= first and row <= last then
      return hunk, i
    end
  end
end

-- The reason goes in the echo area rather than between code lines: virtual lines never wrap,
-- so on a narrow window they get cut off at the edge.
local function echo_hint(bufnr)
  -- Proposals can be placed in buffers that are not on screen (chat edits across files).
  if bufnr ~= vim.api.nvim_get_current_buf() then
    return
  end
  local hunk = M.hunk_at_cursor(bufnr)
  if not hunk then
    return vim.api.nvim_echo({ { "" } }, false, {})
  end
  -- Keys first: without them there is no way to tell how to accept, while the reason can be cut.
  local keys = hint()
  local line = keys .. "  " .. hunk.reason
  while vim.fn.strdisplaywidth(line) > vim.v.echospace do
    line = vim.fn.strcharpart(line, 0, vim.fn.strchars(line) - 1)
  end
  vim.api.nvim_echo({ { line:sub(1, #keys), "TsugaiHint" }, { line:sub(#keys + 1) } }, false, {})
end

local augroup = vim.api.nvim_create_augroup("tsugai_diff", { clear = true })

-- bufnr -> buffer-local keys mapped while its proposals are shown.
local buffer_keys = {}

local function finish_if_empty(bufnr)
  if #(reviews[bufnr] or {}) > 0 then
    return echo_hint(bufnr)
  end
  reviews[bufnr] = nil
  for _, lhs in ipairs(buffer_keys[bufnr] or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
  buffer_keys[bufnr] = nil
  vim.api.nvim_clear_autocmds({ group = augroup, buffer = bufnr })
  vim.api.nvim_echo({ { "" } }, false, {})
end

local function discard(bufnr, index)
  local hunk = table.remove(reviews[bufnr], index)
  clear(bufnr, hunk)
  return hunk
end

-- Moves to the next hunk at or after `row`, wrapping to the first, so a run of
-- accepts and rejects needs no motion keys.
local function advance(bufnr, row)
  local next_row, first_row
  for _, hunk in ipairs(reviews[bufnr]) do
    local first = range(bufnr, hunk)
    if first >= row and (not next_row or first < next_row) then
      next_row = first
    end
    if not first_row or first < first_row then
      first_row = first
    end
  end
  local target = next_row or first_row
  if target then
    vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
  end
end

-- Replaces rows first..last with `lines`. Replacing whole lines would delete up to the start
-- of the next line and drag the next hunk's marks (which stick to the start of their line)
-- into this change, so only the text inside the rows is replaced. Removing the rows
-- entirely has to take the line breaks, and then the next hunk rightly moves up to `first`.
local function apply(bufnr, first, last, lines)
  if #lines == 0 then
    return vim.api.nvim_buf_set_lines(bufnr, first, last + 1, false, {})
  end
  local last_line = vim.api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1]
  vim.api.nvim_buf_set_text(bufnr, first, 0, last, #last_line, lines)
end

-- True when the lines under the hunk were edited after it was proposed; accepting would
-- silently throw those edits away.
local function is_stale(bufnr, hunk)
  local first, last = range(bufnr, hunk)
  local current = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
  local original = split(hunk.old_text)
  if #current ~= #original then
    return true
  end
  for i, line in ipairs(current) do
    if rtrim(line) ~= rtrim(original[i]) then
      return true
    end
  end
  return false
end


function M.accept()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunk, index = M.hunk_at_cursor(bufnr)
  if not hunk then
    return vim.notify("tsugai: no hunk under cursor", vim.log.levels.WARN)
  end
  if is_stale(bufnr, hunk) then
    local message = "tsugai: the code changed since this proposal. %s to redo it, %s to drop it"
    return vim.notify(message:format(key("r"), key("n")), vim.log.levels.WARN)
  end
  local first, last = range(bufnr, hunk)
  discard(bufnr, index)
  apply(bufnr, first, last, hunk.new_lines)
  advance(bufnr, first + #hunk.new_lines)
  finish_if_empty(bufnr)
end

function M.reject()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunk, index = M.hunk_at_cursor(bufnr)
  if not hunk then
    return vim.notify("tsugai: no hunk under cursor", vim.log.levels.WARN)
  end
  local _, last = range(bufnr, hunk)
  discard(bufnr, index)
  advance(bufnr, last + 1)
  finish_if_empty(bufnr)
end

function M.accept_all()
  local bufnr = vim.api.nvim_get_current_buf()
  local index = 1
  while index <= #(reviews[bufnr] or {}) do
    local hunk = reviews[bufnr][index]
    if is_stale(bufnr, hunk) then
      index = index + 1
    else
      local first, last = range(bufnr, hunk)
      discard(bufnr, index)
      apply(bufnr, first, last, hunk.new_lines)
    end
  end
  local skipped = #(reviews[bufnr] or {})
  if skipped > 0 then
    advance(bufnr, 0)
    vim.notify(("tsugai: kept %d hunk(s) whose code changed since the proposal"):format(skipped), vim.log.levels.WARN)
  end
  finish_if_empty(bufnr)
end

local function clear_buffer(bufnr)
  while #(reviews[bufnr] or {}) > 0 do
    discard(bufnr, 1)
  end
  finish_if_empty(bufnr)
end

function M.reject_all()
  clear_buffer(vim.api.nvim_get_current_buf())
end

-- Redraws `hunk` with a revised proposal for the same original lines.
function M.replace(bufnr, hunk, revised)
  local row = range(bufnr, hunk)
  clear(bufnr, hunk)
  hunk.new_lines = split(revised.new_text)
  hunk.reason = revised.reason
  render(bufnr, row, hunk)
  echo_hint(bufnr)
end

function M.jump(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target
  for _, hunk in ipairs(reviews[bufnr] or {}) do
    local first = range(bufnr, hunk)
    if direction > 0 and first > row and (not target or first < target) then
      target = first
    elseif direction < 0 and first < row and (not target or first > target) then
      target = first
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
  end
end

-- Keys mapped in a buffer while its proposals are shown; also listed by :Tsugai help.
function M.review_keys()
  return {
    { key("y"), "accept the hunk under the cursor", M.accept },
    { key("n"), "reject the hunk under the cursor", M.reject },
    { key("r"), "revise the hunk under the cursor", function() require("tsugai.edit").refine() end },
    { key("Y"), "accept every hunk in the buffer", M.accept_all },
    { key("q"), "reject every hunk in the buffer", M.reject_all },
    { "]g", "next hunk", function() M.jump(1) end },
    { "[g", "previous hunk", function() M.jump(-1) end },
  }
end

local function map_keys(bufnr)
  local opts = { buffer = bufnr, nowait = true }
  buffer_keys[bufnr] = {}
  for _, k in ipairs(M.review_keys()) do
    vim.keymap.set("n", k[1], k[3], opts)
    table.insert(buffer_keys[bufnr], k[1])
  end
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = bufnr,
    callback = function() echo_hint(bufnr) end,
  })
end

-- Shows hunks as ghost text over the code they replace.
-- Returns how many hunks could not be located in the buffer.
function M.show(bufnr, hunks, near_row)
  clear_buffer(bufnr)
  reviews[bufnr] = {}
  local missing = 0

  for _, proposal in ipairs(hunks) do
    local old_lines = split(proposal.old_text)
    local row = #old_lines > 0 and locate(bufnr, old_lines, near_row)
    if not row then
      missing = missing + 1
    else
      local hunk = { old_text = proposal.old_text, new_lines = split(proposal.new_text), reason = proposal.reason }
      render(bufnr, row, hunk)
      table.insert(reviews[bufnr], hunk)
    end
  end

  if #reviews[bufnr] > 0 then
    map_keys(bufnr)
    if bufnr == vim.api.nvim_get_current_buf() then
      local first = range(bufnr, reviews[bufnr][1])
      vim.api.nvim_win_set_cursor(0, { first + 1, 0 })
      -- Deferred: leaving visual mode after the mapping returns clears the echo area.
      vim.schedule(function() echo_hint(bufnr) end)
    end
  else
    reviews[bufnr] = nil
  end
  return missing
end

-- Shows proposals that may span files, each in its file's buffer (loaded if needed, without
-- changing windows), and lists them all in the quickfix list. Hunks without a path belong to
-- `default_bufnr`. Returns how many hunks were shown and how many did not match.
function M.show_across(hunks, default_bufnr)
  local order, by_buffer = {}, {}
  for _, hunk in ipairs(hunks) do
    local bufnr = default_bufnr
    if hunk.path and hunk.path ~= "" then
      bufnr = vim.fn.bufadd(vim.fn.fnamemodify(hunk.path, ":p"))
      vim.fn.bufload(bufnr)
      vim.bo[bufnr].buflisted = true
    end
    if not by_buffer[bufnr] then
      by_buffer[bufnr] = {}
      table.insert(order, bufnr)
    end
    table.insert(by_buffer[bufnr], hunk)
  end

  -- show() jumps to the first hunk, which suits an edit of the selection; here the user is
  -- still reading the chat, so the cursor stays where it was.
  local cursor = vim.api.nvim_win_get_cursor(0)
  local missing, items = 0, {}
  for _, bufnr in ipairs(order) do
    missing = missing + M.show(bufnr, by_buffer[bufnr], 0)
    for _, hunk in ipairs(reviews[bufnr] or {}) do
      table.insert(items, { bufnr = bufnr, lnum = range(bufnr, hunk) + 1, text = hunk.reason })
    end
  end

  vim.api.nvim_win_set_cursor(0, cursor)
  if #items > 0 then
    vim.fn.setqflist({}, " ", { title = "tsugai: proposals", items = items })
    local win = vim.api.nvim_get_current_win()
    vim.cmd("botright copen")
    vim.api.nvim_set_current_win(win)
  end
  return #items, missing
end

return M
