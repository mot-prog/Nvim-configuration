return {
  "MeanderingProgrammer/render-markdown.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "nvim-tree/nvim-web-devicons"
  },
  opts = {
    latex = {
      enabled = true,
      -- utftex (libtexprintf) does real multi-line unicode math: stacked
      -- fractions, superscript lines. latex2text is the fallback.
      converter = { "utftex", "latex2text" },
    },
  },
  ft = { "markdown" },
}
