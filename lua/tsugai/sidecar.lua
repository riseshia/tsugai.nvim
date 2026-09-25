local progress = require("tsugai.progress")

local M = {}

local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local TIMEOUT_MS = 10 * 60 * 1000

local state = { chan = nil, pending = nil }

local function log(lines)
  local file = io.open(vim.fn.stdpath("log") .. "/tsugai.log", "a")
  if file then
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
  end
end

local function ensure_started()
  if state.chan then
    return state.chan
  end

  state.chan = vim.fn.jobstart({ "node", ROOT .. "/sidecar/src/main.ts" }, {
    rpc = true,
    cwd = vim.fn.getcwd(),
    on_stderr = function(_, data)
      log(data)
    end,
    on_exit = function(_, code)
      state.chan = nil
      if state.pending then
        state.pending.error = "sidecar exited with code " .. code
        state.pending.done = true
      end
    end,
  })
  if state.chan <= 0 then
    state.chan = nil
    error("tsugai: failed to start sidecar")
  end
  return state.chan
end

-- Called by the sidecar over RPC.
function M.on_event(event)
  local pending = state.pending
  if not pending then
    return
  end

  if event.kind == "progress" then
    progress.append(event)
  elseif event.kind == "done" then
    pending.result = event.result
    pending.done = true
  elseif event.kind == "error" then
    pending.error = event.message
    pending.done = true
  end
end

-- Blocks the editor until the sidecar answers, keeping the progress float live.
function M.request(method, params)
  local chan = ensure_started()
  local pending = { done = false }
  state.pending = pending
  progress.open(method)

  vim.rpcnotify(chan, method, params)
  local finished = function()
    return pending.done
  end
  local ok, status = vim.wait(TIMEOUT_MS, finished, 50)
  if not ok then
    vim.rpcnotify(chan, "cancel")
    vim.wait(10 * 1000, finished, 50)
    pending.error = status == -2 and "cancelled" or "timed out"
  end

  state.pending = nil
  progress.close()
  if pending.error then
    error("tsugai: " .. pending.error, 0)
  end
  return pending.result
end

return M
