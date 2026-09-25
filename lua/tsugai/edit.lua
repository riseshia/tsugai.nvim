local diff = require("tsugai.diff")
local selection = require("tsugai.selection")
local sidecar = require("tsugai.sidecar")

local M = {}

local function show(bufnr, result, near_row)
  if #result.hunks == 0 then
    return vim.notify("tsugai: no changes proposed. " .. result.message)
  end
  local missing = diff.show(bufnr, result.hunks, near_row)
  if missing > 0 then
    vim.notify(("tsugai: %d hunk(s) did not match the buffer and were dropped"):format(missing), vim.log.levels.WARN)
  end
end

-- A marker at the start of a line, optionally after comment characters: `# @@ai`, `// @@ai`, `<!-- @@ai`.
local MARKER = "^%s*%p*%s*@@ai"

-- Consecutive marker lines form one template, so an instruction can span several lines.
local function find_templates(bufnr, first_line, last_line)
  local templates = {}
  local current
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, first_line - 1, last_line, false)) do
    local lnum = first_line + i - 1
    if line:match(MARKER) then
      if current and current.end_line == lnum - 1 then
        current.end_line = lnum
        current.text = current.text .. "\n" .. line
      else
        current = { start_line = lnum, end_line = lnum, text = line }
        table.insert(templates, current)
      end
    end
  end
  return templates
end

local function request(bufnr, params, near_row)
  params.bufnr = bufnr
  params.path = vim.api.nvim_buf_get_name(bufnr)
  local ok, result = pcall(sidecar.request, "edit", params)
  if not ok then
    return vim.notify(result, vim.log.levels.ERROR)
  end
  show(bufnr, result, near_row)
end

-- Normal mode: process every @@ai template in the buffer.
function M.run()
  local bufnr = vim.api.nvim_get_current_buf()
  local templates = find_templates(bufnr, 1, vim.api.nvim_buf_line_count(bufnr))
  if #templates == 0 then
    return vim.notify("tsugai: no @@ai templates in this buffer. Select lines to edit them instead", vim.log.levels.WARN)
  end
  request(bufnr, { templates = templates }, templates[1].start_line - 1)
end

-- Visual mode: templates inside the selection are processed as they are; otherwise ask
-- for an instruction. Called after leaving visual mode, so '< and '> hold the selection.
function M.run_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local selected = selection.get(bufnr)
  local templates = find_templates(bufnr, selected.start_line, selected.end_line)
  if #templates > 0 then
    return request(bufnr, { templates = templates }, templates[1].start_line - 1)
  end

  local instruction = vim.fn.input("tsugai edit> ")
  if instruction == "" then
    return
  end
  vim.cmd.echo([[""]])
  request(bufnr, { instruction = instruction, selection = selected }, selected.start_line - 1)
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
