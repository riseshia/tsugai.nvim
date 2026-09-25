local M = {}

M.config = {
  -- Free-form preferences appended to Claude's system prompt, e.g. "Answer in Korean."
  instructions = "",
}

-- Takes effect when the sidecar starts, which happens on the first request.
function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})
end

return M
