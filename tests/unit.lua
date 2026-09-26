-- Lua-side behavior without the sidecar: `nvim --clean -l tests/unit.lua`
local t = require("tests.helper")

-- edit.lua talks to the sidecar only through request(); record the calls instead.
local requests = {}
local reply = { hunks = {}, message = "" }
package.loaded["tsugai.sidecar"] = {
  request = function(method, params)
    table.insert(requests, { method = method, params = params })
    return reply
  end,
}

local command = require("tsugai.command")
local diff = require("tsugai.diff")
local edit = require("tsugai.edit")
local tsugai = require("tsugai")

local function extmarks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
end

t.test("command check allows text-editing commands", function()
  for _, cmd in ipairs({
    [[%s/\<fetch_user\>/load_user/g]],
    [[cfdo %s/\<a\>/b/ge | update]],
    [[g/debug/d]],
    [['<,'>sort]],
    [[%s/a\|b/c/g]],
  }) do
    t.eq(command.check(cmd), nil, cmd)
  end
end)

t.test("command check refuses anything that can reach the shell or run code", function()
  for _, cmd in ipairs({
    [[!rm -rf x]],
    [[%!sort]],
    [[g/x/!ls]],
    [[s/a/\=system("ls")/]],
    [[lua print(1)]],
    [[cfdo %s/a/b/ge | w /tmp/x]],
    [[exe "norm ihi"]],
    [[g/x/s/a/b/|lua 1]],
  }) do
    t.ok(command.check(cmd), "refused: " .. cmd)
  end
end)

t.test("a proposal only ghosts the part of a line that changes", function()
  local buf = t.buffer({ "def triple(n) = n * 3", "end" })
  diff.show(buf, { { old_text = "def triple(n) = n * 3", new_text = "def triple(n) = n + n + n", reason = "r" } }, 0)
  local overlay = vim.tbl_filter(function(m) return m[4].virt_text end, extmarks(buf))
  t.eq(#overlay, 1)
  t.eq(overlay[1][3], #"def triple(n) = n ", "overlay starts at the first changed column")
  t.eq(overlay[1][4].virt_text[1][1], "+ n + n")
  diff.reject_all()
end)

t.test("accepting replaces the lines, moves to the next hunk and unmaps when done", function()
  local buf = t.buffer({ "a = 1", "keep", "b = 2" })
  diff.show(buf, {
    { old_text = "a = 1", new_text = "a = 10", reason = "first" },
    { old_text = "b = 2", new_text = "b = 20", reason = "second" },
  }, 0)
  t.ok(vim.fn.maparg(tsugai.key("y"), "n") ~= "", "accept key is mapped while reviewing")
  diff.accept()
  t.eq(t.lines(buf), { "a = 10", "keep", "b = 2" })
  t.eq(vim.api.nvim_win_get_cursor(0)[1], 3, "cursor moved to the next hunk")
  diff.reject()
  t.eq(t.lines(buf), { "a = 10", "keep", "b = 2" })
  t.eq(#extmarks(buf), 0, "no marks left")
  t.eq(vim.fn.maparg(tsugai.key("y"), "n"), "", "review keys are unmapped")
end)

t.test("a hunk whose lines were edited after the proposal cannot be accepted", function()
  local buf = t.buffer({ "x = 1" })
  diff.show(buf, { { old_text = "x = 1", new_text = "x = 2", reason = "r" } }, 0)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "x = 1 # edited" })
  local messages = t.notifications(diff.accept)
  t.eq(t.lines(buf), { "x = 1 # edited" })
  t.ok(messages[1]:find("changed since this proposal"), "explains why")
  diff.reject_all()
end)

t.test("accept all skips stale hunks", function()
  local buf = t.buffer({ "a", "b" })
  diff.show(buf, {
    { old_text = "a", new_text = "A", reason = "r" },
    { old_text = "b", new_text = "B", reason = "r" },
  }, 0)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "b!" })
  t.notifications(diff.accept_all)
  t.eq(t.lines(buf), { "A", "b!" })
  diff.reject_all()
end)

t.test("normal-mode edit sends every @@ai template, grouping consecutive lines", function()
  requests = {}
  t.buffer({ "class A", "  # @@ai first", "  # @@ai  continued", "", "  // @@ai second", "end" })
  edit.run()
  t.eq(#requests, 1)
  local templates = requests[1].params.templates
  t.eq(#templates, 2)
  t.eq({ templates[1].start_line, templates[1].end_line }, { 2, 3 })
  t.eq({ templates[2].start_line, templates[2].end_line }, { 5, 5 })
end)

t.test("a selection with templates in it sends only those, without asking", function()
  requests = {}
  local buf = t.buffer({ "# @@ai one", "x", "# @@ai two" })
  t.select(buf, 3, 3)
  t.with_input("should not be asked", edit.run_selection)
  t.eq(#requests[1].params.templates, 1)
  t.eq(requests[1].params.templates[1].start_line, 3)
  t.eq(requests[1].params.instruction, nil)
end)

t.test("a selection without templates asks for an instruction", function()
  requests = {}
  local buf = t.buffer({ "x = 1", "y = 2" })
  t.select(buf, 1, 2)
  t.with_input("rename", edit.run_selection)
  t.eq(requests[1].params.instruction, "rename")
  t.eq(requests[1].params.selection.text, "x = 1\ny = 2")
end)

t.test("the prefix setting moves every key, and help follows it", function()
  tsugai.setup({ prefix = "<Space>j" })
  t.eq(vim.fn.maparg(" fe", "n"), "", "old prefix is unmapped")
  t.ok(vim.fn.maparg(" je", "n") ~= "", "new prefix is mapped")
  require("tsugai.help").open()
  local text = table.concat(t.lines(), "\n")
  t.ok(text:find("<Space>je", 1, true), "help lists the new edit key")
  t.ok(text:find("<Space>jy", 1, true), "help lists the new accept key")
  t.ok(not text:find("<Space>f", 1, true), "help has no old keys")
  vim.cmd("close")
  tsugai.setup({ prefix = "<Space>f" })
end)

t.run()
