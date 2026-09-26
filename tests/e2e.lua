-- The whole path with scripted model answers: `nvim --clean -l tests/e2e.lua`.
-- Neovim → sidecar → Agent SDK → Claude Code binary → tests/mock_api.mjs, and back
-- through the tools into the buffers. Needs `npm install` in sidecar/.
local t = require("tests.helper")

-- A hung request would otherwise block until the sidecar's own timeout.
vim.defer_fn(function()
  io.stdout:write("TIMEOUT: e2e run took over 3 minutes\n")
  os.exit(2)
end, 3 * 60 * 1000)

local project = vim.fn.tempname()
vim.fn.mkdir(project, "p")
local function write(name, lines)
  vim.fn.writefile(lines, project .. "/" .. name)
  return project .. "/" .. name
end
local users = write("users.rb", {
  "module Users",
  "  def self.fetch_user(id)",
  "    { id: id }",
  "  end",
  "",
  "  def self.fetch_users(ids)",
  "    ids.map { |id| fetch_user(id) }",
  "  end",
  "end",
})
local app = write("app.rb", { 'require_relative "users"', "", "user = Users.fetch_user(1)", "puts user" })
write("cart.rb", { "class Cart", "  # @@ai total price of the items", "end" })

local rules = {
  {
    match = "E2E_EDIT",
    tool = "propose_edit",
    input = { hunks = { {
      old_text = "    ids.map { |id| fetch_user(id) }",
      new_text = "    ids.each_with_object([]) { |id, users| users << fetch_user(id) }",
      reason = "build the array explicitly",
    } } },
  },
  {
    match = "E2E_REFINE",
    tool = "propose_edit",
    input = { hunks = { {
      old_text = "    ids.map { |id| fetch_user(id) }",
      new_text = "    ids.each_with_object([]) { |id, list| list << fetch_user(id) }",
      reason = "name it list",
    } } },
  },
  {
    match = "@@ai total price",
    tool = "propose_edit",
    input = { hunks = { {
      old_text = "  # @@ai total price of the items",
      new_text = "  def total_price\n    @items.sum(&:price)\n  end",
      reason = "sum the prices",
    } } },
  },
  { match = "E2E_ASK", text = "It is called from app.rb:3." },
  {
    match = "E2E_RENAME",
    tool = "propose_command",
    input = {
      title = "fetch_user → load_user",
      command = [[cfdo %s/\<fetch_user\>/load_user/ge | update]],
      explanation = { { token = "cfdo", meaning = "for each file in the quickfix list" } },
      locations = {
        { path = users, line = 2, text = "  def self.fetch_user(id)" },
        { path = users, line = 7, text = "    ids.map { |id| fetch_user(id) }" },
        { path = app, line = 3, text = "user = Users.fetch_user(1)" },
      },
    },
  },
  {
    match = "E2E_DANGER",
    tool = "propose_command",
    input = { title = "wipe", command = "!rm -rf " .. project, explanation = {}, locations = {} },
  },
}
local rules_file = vim.fn.tempname()
vim.fn.writefile({ vim.json.encode(rules) }, rules_file)

local port_file = vim.fn.tempname()
local mock = vim.system({ "node", t.root .. "/tests/mock_api.mjs", rules_file, port_file })
assert(vim.wait(10000, function() return vim.fn.filereadable(port_file) == 1 end), "mock API did not start")

-- The sidecar inherits these: talk to the mock, with a config dir of its own so no real
-- login or settings are used.
vim.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:" .. vim.fn.readfile(port_file)[1]
vim.env.ANTHROPIC_API_KEY = "sk-mock"
vim.env.CLAUDE_CONFIG_DIR = vim.fn.tempname()
vim.fn.mkdir(vim.env.CLAUDE_CONFIG_DIR, "p")
vim.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
vim.cmd.cd(project)

local diff = require("tsugai.diff")
local edit = require("tsugai.edit")
local chat = require("tsugai.chat")

t.test("edit: a selection comes back as ghost text, a revision replaces it, accept applies it", function()
  vim.cmd.edit(users)
  local buf = vim.api.nvim_get_current_buf()
  t.select(buf, 7, 7)
  t.with_input("E2E_EDIT use each_with_object", edit.run_selection)
  t.ok(diff.hunk_at_cursor(buf), "the proposal is shown at the selection")

  t.with_input("E2E_REFINE name it list", edit.refine)
  diff.accept()
  t.eq(vim.api.nvim_buf_get_lines(buf, 6, 7, false)[1], "    ids.each_with_object([]) { |id, list| list << fetch_user(id) }")
  vim.cmd("silent! edit!")
end)

t.test("templates: @@ai lines are sent and come back as a proposal in their place", function()
  vim.cmd.edit(project .. "/cart.rb")
  local buf = vim.api.nvim_get_current_buf()
  edit.run()
  diff.accept()
  t.eq(t.lines(buf), { "class Cart", "  def total_price", "    @items.sum(&:price)", "  end", "end" })
  vim.cmd("silent! edit!")
end)

t.test("chat: the answer is streamed into the chat buffer", function()
  vim.cmd.edit(app)
  t.with_input("E2E_ASK where is fetch_user used?", chat.ask)
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("tsugai://chat"), 0, -1, false), "\n")
  t.ok(text:find("E2E_ASK where is fetch_user used?", 1, true), "the question is in the chat")
  t.ok(text:find("It is called from app.rb:3.", 1, true), "the answer is in the chat")
end)

t.test("chat: a proposed command shows a card and runs from it", function()
  vim.cmd.edit(app)
  t.with_input("E2E_RENAME rename fetch_user to load_user", chat.ask)
  t.ok(vim.api.nvim_win_get_config(0).relative ~= "", "the card has focus")
  t.eq(#vim.fn.getqflist(), 3, "targets are in the quickfix list")
  -- :silent keeps cfdo's per-file messages out of the report.
  _G.run_card = vim.fn.maparg("<CR>", "n", false, true).callback
  vim.cmd("silent lua run_card()")

  local saved = table.concat(vim.fn.readfile(users), "\n")
  t.ok(saved:find("def self.load_user(id)", 1, true), "the definition is renamed on disk")
  t.ok(saved:find("def self.fetch_users(ids)", 1, true), "fetch_users is left alone")
  t.eq(vim.fn.readfile(app)[3], "user = Users.load_user(1)")
end)

t.test("chat: a command that reaches the shell is refused before any card", function()
  vim.cmd.edit(app)
  vim.fn.setqflist({}, "r", { title = "before" })
  t.with_input("E2E_DANGER clean up", chat.ask)
  t.eq(vim.api.nvim_win_get_config(0).relative, "", "no card")
  t.eq(vim.fn.getqflist({ title = 1 }).title, "before", "quickfix untouched")
  t.ok(vim.fn.isdirectory(project) == 1, "the project is still there")
end)

t.test("doctor: the sidecar is reported as running", function()
  local status = require("tsugai.sidecar").status()
  t.ok(status.running, "running")
  t.ok(status.requests >= 5, "requests are counted")
end)

t.run(function() mock:kill("sigterm") end)
