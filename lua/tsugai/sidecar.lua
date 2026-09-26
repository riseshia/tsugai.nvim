local progress = require("tsugai.progress")

local M = {}

M.ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
M.LOG_PATH = vim.fn.stdpath("log") .. "/tsugai.log"
local TIMEOUT_MS = 10 * 60 * 1000

local state = { chan = nil, pending = nil, pid = nil, cwd = nil, started_at = nil, requests = 0, last_exit = nil }

local function log(line)
  local file = io.open(M.LOG_PATH, "a")
  if file then
    file:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
    file:close()
  end
end

local function ensure_started()
  if state.chan then
    return state.chan
  end

  local cwd = vim.fn.getcwd()
  state.chan = vim.fn.jobstart({ "node", M.ROOT .. "/sidecar/src/main.ts" }, {
    rpc = true,
    cwd = cwd,
    env = { TSUGAI_INSTRUCTIONS = require("tsugai").config.instructions },
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          log("sidecar: " .. line)
        end
      end
    end,
    on_exit = function(_, code)
      log(("sidecar exited with code %d"):format(code))
      state.chan, state.pid, state.last_exit = nil, nil, code
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
  state.pid, state.cwd, state.started_at, state.requests = vim.fn.jobpid(state.chan), cwd, os.time(), 0
  log(("sidecar started (pid %d, cwd %s)"):format(state.pid, cwd))
  return state.chan
end

-- Called by the sidecar over RPC.
function M.on_event(event)
  local pending = state.pending
  if not pending then
    return
  end

  if event.kind == "progress" then
    pending.on_progress(event)
  elseif event.kind == "done" then
    pending.result = event.result
    pending.done = true
  elseif event.kind == "error" then
    pending.error = event.message
    pending.done = true
  end
end

-- Blocks the editor until the sidecar answers. Progress goes to `on_progress` when given,
-- otherwise to the progress float.
function M.request(method, params, on_progress)
  local chan = ensure_started()
  local pending = { done = false, on_progress = on_progress or progress.append }
  state.pending = pending
  if not on_progress then
    progress.open(method)
  end

  local started = vim.uv.hrtime()
  state.requests = state.requests + 1
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
  local seconds = (vim.uv.hrtime() - started) / 1e9
  log(("%s %s in %.1fs"):format(method, pending.error and ("failed: " .. pending.error) or "done", seconds))
  if pending.error then
    error("tsugai: " .. pending.error, 0)
  end
  return pending.result
end

-- For :checkhealth. last_exit is the exit code of a sidecar that is no longer running.
function M.status()
  return {
    running = state.chan ~= nil,
    pid = state.pid,
    cwd = state.cwd,
    started_at = state.started_at,
    requests = state.requests,
    last_exit = state.last_exit,
  }
end

return M
