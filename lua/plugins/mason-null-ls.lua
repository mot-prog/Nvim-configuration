-- Control which null-ls sources mason-null-ls auto-registers.
-- By default it registers a null-ls builtin for every installed Mason package,
-- which would re-add the stock prettier source (it hangs in this environment —
-- see lua/plugins/none-ls.lua, where prettier is wired up manually instead).

---@type LazySpec
return {
  "jay-babu/mason-null-ls.nvim",
  opts = {
    handlers = {
      -- no-op: do not auto-register the stock prettier null-ls builtin
      prettier = function() end,
    },
  },
}
