local diff = require("tsugai.diff")
local sidecar = require("tsugai.sidecar")

local M = {}

-- Called after leaving visual mode, so the '< and '> marks hold the selection.
function M.run()
  local bufnr = vim.api.nvim_get_current_buf()
  local start_line, end_line = vim.fn.line("'<"), vim.fn.line("'>")
  local instruction = vim.fn.input("tsugai edit> ")
  if instruction == "" then
    return
  end
  vim.cmd.echo([[""]])

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local ok, result = pcall(sidecar.request, "edit", {
    instruction = instruction,
    selection = {
      bufnr = bufnr,
      path = vim.api.nvim_buf_get_name(bufnr),
      start_line = start_line,
      end_line = end_line,
      text = table.concat(lines, "\n"),
    },
  })
  if not ok then
    return vim.notify(result, vim.log.levels.ERROR)
  end

  if #result.hunks == 0 then
    return vim.notify("tsugai: no changes proposed. " .. result.message)
  end
  local missing = diff.show(bufnr, result.hunks, start_line - 1)
  if missing > 0 then
    vim.notify(("tsugai: %d hunk(s) did not match the buffer and were dropped"):format(missing), vim.log.levels.WARN)
  end
end

-- Asks for a revised proposal for the hunk under the cursor; the original lines stay the same.
function M.refine()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunk = diff.hunk_at_cursor(bufnr)
  if not hunk then
    return vim.notify("tsugai: no hunk under cursor", vim.log.levels.WARN)
  end
  local instruction = vim.fn.input("tsugai refine> ")
  if instruction == "" then
    return
  end
  vim.cmd.echo([[""]])

  local ok, result = pcall(sidecar.request, "refine", {
    instruction = instruction,
    bufnr = bufnr,
    path = vim.api.nvim_buf_get_name(bufnr),
    hunk = { old_text = hunk.old_text, new_text = table.concat(hunk.new_lines, "\n"), reason = hunk.reason },
  })
  if not ok then
    return vim.notify(result, vim.log.levels.ERROR)
  end

  local revised = result.hunks[1]
  if not revised then
    return vim.notify("tsugai: no revision proposed. " .. result.message)
  end
  diff.replace(bufnr, hunk, revised)
end

return M
