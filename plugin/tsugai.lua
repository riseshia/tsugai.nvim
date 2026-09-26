if vim.g.loaded_tsugai then
  return
end
vim.g.loaded_tsugai = true

require("tsugai").map_keys()

vim.api.nvim_create_user_command("Tsugai", function(opts) require("tsugai").command(opts) end, {
  nargs = 1,
  complete = function() return require("tsugai").subcommands() end,
  desc = "tsugai: help, doctor or log",
})
