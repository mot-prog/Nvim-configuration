return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
      "nvim-tree/nvim-web-devicons"
    },
    opts = {
      latex = {
        -- render-latex.nvim owns LaTeX now (real PNG rendering in kitty).
        -- Set enabled = true to get the unicode fallback back (e.g. in konsole).
        enabled = false,
        converter = { "utftex", "latex2text" },
      },
    },
    ft = { "markdown" },
  },
  {
    -- VSCode-style display math: $$ blocks rendered as transparent PNG images
    -- via kitty graphics protocol; inline math concealed. Needs kitty (or nvim
    -- image API); falls back gracefully elsewhere.
    "techwizrd/render-latex.nvim",
    ft = { "markdown" },
    opts = {
      render = {
        preset = "match_text", -- image size follows the surrounding text
        inline = "conceal",
        live_preview = true,
      },
    },
    config = function(_, opts)
      -- inline math conceal (and render-markdown) need conceal enabled;
      -- original text reappears while inserting
      vim.opt.conceallevel = 2
      vim.opt.concealcursor = "nc"
      require("render_latex").setup(opts)
    end,
  },
  {
    -- inline images for markdown (and image files opened in nvim)
    "3rd/image.nvim",
    build = false, -- skip the luarocks magick rock; we use the CLI processor
    opts = {
      backend = "kitty", -- running in kitty now; sixel was the konsole fallback
      processor = "magick_cli",
      integrations = {
        markdown = {
          enabled = true,
          filetypes = { "markdown" },
          only_render_image_at_cursor = false,
          download_remote_images = true,
        },
      },
      max_height_window_percentage = 50,
    },
    ft = { "markdown" },
  },
}
