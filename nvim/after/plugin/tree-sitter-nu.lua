local ok, treesitter = pcall(require, "nvim-treesitter")
if not ok then
  return
end

treesitter.setup({})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "nu",
  desc = "Enable Tree-sitter highlighting for Nushell",
  callback = function(args)
    pcall(vim.treesitter.start, args.buf, "nu")
  end,
})
