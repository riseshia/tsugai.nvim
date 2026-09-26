local M = {}

local sidecar = require("tsugai.sidecar")

-- Node strips TypeScript types without a flag from these versions on; older ones cannot
-- run sidecar/src/main.ts at all.
local function node_ok(major, minor)
  return major > 23 or (major == 23 and minor >= 6) or (major == 22 and minor >= 18)
end

-- The Agent SDK ships the Claude Code binary as a per-platform package, named like Node's
-- process.platform and process.arch.
local function sdk_binary_package()
  local uname = vim.uv.os_uname()
  local platform = ({ Linux = "linux", Darwin = "darwin" })[uname.sysname] or uname.sysname:lower()
  local arch = ({ x86_64 = "x64", aarch64 = "arm64", arm64 = "arm64" })[uname.machine] or uname.machine
  return ("claude-agent-sdk-%s-%s"):format(platform, arch)
end

function M.check()
  vim.health.start("tsugai: environment")

  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.11 or later is required")
  end

  if vim.fn.executable("node") == 0 then
    vim.health.error("`node` is not on PATH", "Install Node.js 22.18 or later")
  else
    local version = vim.trim(vim.fn.system({ "node", "--version" }))
    local major, minor = version:match("^v(%d+)%.(%d+)")
    if major and node_ok(tonumber(major), tonumber(minor)) then
      vim.health.ok("Node.js " .. version)
    else
      vim.health.error("Node.js " .. version .. " cannot run TypeScript directly", "Install Node.js 22.18 or later")
    end
  end

  local modules = sidecar.ROOT .. "/sidecar/node_modules/@anthropic-ai"
  if vim.fn.isdirectory(modules .. "/claude-agent-sdk") == 0 then
    vim.health.error("Sidecar dependencies are not installed", "Run ./build.sh in " .. sidecar.ROOT)
  elseif vim.fn.isdirectory(modules .. "/" .. sdk_binary_package()) == 0 then
    vim.health.error(
      "Claude Code binary for this platform is missing (" .. sdk_binary_package() .. ")",
      "node_modules may come from another machine. Run ./build.sh in " .. sidecar.ROOT
    )
  else
    vim.health.ok("Sidecar dependencies are installed")
  end

  -- Only presence is checked; whether the credentials work shows on the first request.
  if vim.env.ANTHROPIC_API_KEY and vim.env.ANTHROPIC_API_KEY ~= "" then
    vim.health.ok("ANTHROPIC_API_KEY is set")
  elseif vim.fn.filereadable(vim.fn.expand("~/.claude/.credentials.json")) == 1 then
    vim.health.ok("Claude Code login found (~/.claude/.credentials.json)")
  else
    vim.health.warn(
      "No Claude credentials found",
      { "Log in with the `claude` CLI or set ANTHROPIC_API_KEY", "On macOS the login is kept in the Keychain, which this check cannot see" }
    )
  end

  vim.health.start("tsugai: sidecar")
  local status = sidecar.status()
  if status.running then
    vim.health.ok(("Running: pid %d, cwd %s, up since %s, %d request(s)"):format(
      status.pid, status.cwd, os.date("%H:%M:%S", status.started_at), status.requests
    ))
  elseif status.last_exit then
    vim.health.warn(("Not running: last exited with code %d"):format(status.last_exit), "See :Tsugai log")
  else
    vim.health.info("Not started yet. It starts on the first request")
  end
  vim.health.info("Log: " .. sidecar.LOG_PATH)
end

return M
