local M = {}

local MODES = { n = "normal", x = "visual" }

-- Global keys come from the mappings themselves (their `desc`), so the list follows the
-- configured prefix and never drifts from what is actually mapped.
local function global_keys()
  local rows = {}
  for mode, name in pairs(MODES) do
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      local desc = map.desc and map.desc:match("^tsugai: (.*)")
      if desc then
        table.insert(rows, { vim.fn.keytrans(map.lhs), name, desc })
      end
    end
  end
  table.sort(rows, function(a, b)
    return a[1] == b[1] and a[2] < b[2] or a[1] < b[1]
  end)
  return rows
end

local function lines()
  local out = { "Keys", "" }
  for _, row in ipairs(global_keys()) do
    table.insert(out, ("  %-12s %-7s %s"):format(row[1], row[2], row[3]))
  end
  vim.list_extend(out, { "", "While reviewing proposals", "" })
  for _, k in ipairs(require("tsugai.diff").review_keys()) do
    table.insert(out, ("  %-12s %s"):format(k[1], k[2]))
  end
  vim.list_extend(out, {
    "",
    "Commands",
    "",
    "  :Tsugai help     this window",
    "  :Tsugai doctor   check the setup and the sidecar (:checkhealth tsugai)",
    "  :Tsugai log      open the log",
    "",
    "Templates: write `@@ai <what you want>` in a comment, then use the edit key in normal mode.",
  })
  return out
end

function M.open()
  local content = lines()
  local width = 0
  for _, line in ipairs(content) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#content, vim.o.lines - 4)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " tsugai ",
    footer = " q to close ",
    footer_pos = "right",
  })
  local ns = vim.api.nvim_create_namespace("tsugai_help")
  for i, line in ipairs(content) do
    if line ~= "" and not line:match("^%s") and not line:match("^Templates") then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = "Title" })
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })
end

return M
