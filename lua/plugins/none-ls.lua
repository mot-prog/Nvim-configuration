-- Customize None-ls sources
-- none-ls provides the formatters used by AstroNvim's built-in "format on save"
-- (AstroNvim runs vim.lsp.buf.format() in a BufWritePre autocmd when autoformat is on)

---@type LazySpec
return {
  "nvimtools/none-ls.nvim",
  opts = function(_, opts)
    -- opts variable is the default configuration table for the setup function call
    local null_ls = require "null-ls"

    -- Check supported formatters and linters
    -- https://github.com/nvimtools/none-ls.nvim/tree/main/lua/null-ls/builtins/formatting
    -- https://github.com/nvimtools/none-ls.nvim/tree/main/lua/null-ls/builtins/diagnostics

    -- Only insert new sources, do not replace the existing ones
    -- (If you wish to replace, use `opts.sources = {}` instead of the `list_insert_unique` function)
    -- NOTE: the stock null_ls.builtins.formatting.prettier source hangs in this
    -- environment (its dynamic_command/cwd resolution never resolves, which blocks
    -- every formatting request for those filetypes), so prettier is wired up as a
    -- plain custom source that just pipes the buffer through the prettier binary.
    local prettier_filetypes = {
      "json",
      "javascript",
      "javascriptreact",
      "typescript",
      "typescriptreact",
      "css",
      "html",
      "markdown",
      "yaml",
    }
    local prettier = {
      name = "prettier",
      method = null_ls.methods.FORMATTING,
      filetypes = prettier_filetypes,
      generator = {
        fn = function(params, done)
          local bin = vim.fn.exepath("prettier")
          if bin == "" then bin = vim.fn.expand("~/.local/share/nvim/mason/bin/prettier") end
          local input = table.concat(params.content, "\n")
          vim.system({ bin, "--stdin-filepath", params.bufname }, { text = true, stdin = input }, function(res)
            vim.schedule(function()
              if res.code == 0 and res.stdout and res.stdout ~= "" then
                done({ { text = res.stdout } })
              else
                done()
              end
            end)
          end)
        end,
        async = true,
      },
    }

    opts.sources = require("astrocore").list_insert_unique(opts.sources, {
      -- Formatters used on save (add more: https://github.com/nvimtools/none-ls.nvim/tree/main/lua/null-ls/builtins/formatting)
      null_ls.builtins.formatting.stylua, -- Lua
      prettier, -- JS/TS/JSX/TSX, JSON, CSS, HTML, Markdown, YAML
      null_ls.builtins.formatting.clang_format, -- C/C++ (binary already on PATH)
    })
  end,
}
