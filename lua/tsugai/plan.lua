local M = {}

local function card_lines(plan)
  local lines = { plan.summary, "" }
  for i, step in ipairs(plan.steps) do
    table.insert(lines, ("  %d. %s"):format(i, step))
  end
  table.insert(lines, "")
  local width = 0
  for _, file in ipairs(plan.files) do
    width = math.max(width, vim.fn.strdisplaywidth(file.path))
  end
  for _, file in ipairs(plan.files) do
    local mark = file.action == "create" and "+" or "~"
    table.insert(lines, ("  %s %s%s  %s"):format(mark, file.path, string.rep(" ", width - vim.fn.strdisplaywidth(file.path)), file.note))
  end
  vim.list_extend(lines, { "", "<CR> carry it out   q decline" })
  return lines
end

-- Buffers with unsaved changes would diverge from the files Claude edits on disk.
local function unsaved_buffers()
  local names = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1, bufmodified = 1 })) do
    if vim.bo[info.bufnr].buftype == "" then
      table.insert(names, vim.fn.fnamemodify(info.name, ":~:."))
    end
  end
  return names
end

-- Shows a plan Claude proposed from the chat. Accepting has Claude carry it out.
function M.propose(plan)
  require("tsugai.card").open(plan.title, card_lines(plan), {
    ["<CR>"] = function(close)
      local unsaved = unsaved_buffers()
      if #unsaved > 0 then
        return vim.notify("tsugai: save these first (:wa), then accept again: " .. table.concat(unsaved, ", "), vim.log.levels.WARN)
      end
      close()
      require("tsugai.chat").execute_plan(plan)
    end,
    q = function(close)
      close()
      require("tsugai.chat").note("Plan declined.")
    end,
  })
end

return M
