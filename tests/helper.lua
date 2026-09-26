-- Tiny test harness for `nvim --clean -l tests/<file>.lua`: no plugin dependencies.
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
M.root = root
vim.opt.runtimepath:prepend(root)
vim.cmd.runtime("plugin/tsugai.lua")

-- Under `nvim -l` echoes and notifications go straight to stdout, in the middle of the
-- report. Tests that care about a message capture it with M.notifications.
vim.api.nvim_echo = function() end
vim.notify = function() end
-- Same for the file info and "written" messages of :edit and :update.
vim.opt.shortmess:append("FW")

local cases = {}

function M.test(name, fn)
  table.insert(cases, { name = name, fn = fn })
end

function M.eq(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(("%sexpected %s, got %s"):format(label and (label .. ": ") or "", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.ok(value, label)
  if not value then
    error((label or "expected a truthy value") .. ", got " .. vim.inspect(value), 2)
  end
end

-- A scratch buffer with `lines`, shown in the current window.
function M.buffer(lines, name)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

function M.lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

-- Captures vim.notify messages while `fn` runs.
function M.notifications(fn)
  local messages = {}
  local original = vim.notify
  vim.notify = function(msg) table.insert(messages, msg) end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    error(err, 0)
  end
  return messages
end

-- Answers vim.fn.input() with `answer` while `fn` runs.
function M.with_input(answer, fn)
  local original = vim.fn.input
  vim.fn.input = function() return answer end
  local ok, err = pcall(fn)
  vim.fn.input = original
  if not ok then
    error(err, 0)
  end
end

-- Sets the last visual selection marks, as leaving visual mode would.
function M.select(buf, first, last)
  vim.api.nvim_buf_set_mark(buf, "<", first, 0, {})
  vim.api.nvim_buf_set_mark(buf, ">", last, 0, {})
end

-- `cleanup` runs after every case, before the process exits.
function M.run(cleanup)
  local failed = 0
  for _, case in ipairs(cases) do
    -- Each case starts from a clean editor: one window, no leftover buffers.
    vim.cmd("silent! only | enew!")
    local ok, err = xpcall(case.fn, debug.traceback)
    if ok then
      io.stdout:write("ok   ", case.name, "\n")
    else
      failed = failed + 1
      io.stdout:write("FAIL ", case.name, "\n", err, "\n")
    end
  end
  io.stdout:write(("\n%d passed, %d failed\n"):format(#cases - failed, failed))
  if cleanup then
    cleanup()
  end
  os.exit(failed == 0 and 0 or 1)
end

return M
