if vim.g.loaded_tsugai then
  return
end
vim.g.loaded_tsugai = true

require("tsugai").map_keys()
