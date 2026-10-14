-- Customize Mason
-- mason-tool-installer auto-installs the binaries for the formatters used by format-on-save
-- (configured in lua/plugins/none-ls.lua)

---@type LazySpec
return {
  -- use mason-tool-installer for automatically installing Mason packages
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    -- overrides `require("mason-tool-installer").setup(...)`
    opts = {
      -- Make sure to use the names found in `:Mason`
      ensure_installed = {
        -- install formatters (used by format-on-save, see lua/plugins/none-ls.lua)
        "stylua", -- Lua
        "prettier", -- JS/TS, JSON, CSS, HTML, Markdown, YAML
      },
    },
  },
}
