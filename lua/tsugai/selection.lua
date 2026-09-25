local M = {}

-- Reads the last visual selection. Call it after leaving visual mode, so '< and '> are set.
function M.get(bufnr)
  local start_line, end_line = vim.fn.line("'<"), vim.fn.line("'>")
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  return {
    bufnr = bufnr,
    path = vim.api.nvim_buf_get_name(bufnr),
    start_line = start_line,
    end_line = end_line,
    text = table.concat(lines, "\n"),
  }
end

return M
