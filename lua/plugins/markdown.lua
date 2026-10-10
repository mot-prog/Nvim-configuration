return {
  "MeanderingProgrammer/render-markdown.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "nvim-tree/nvim-web-devicons"
  },
  opts = {
    latex = {
      enabled = true,
      converter = "latex2text",},
  },
  ft = { "markdown" },
}
