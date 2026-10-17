return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
      "nvim-tree/nvim-web-devicons"
    },
    opts = {
      latex = {
        -- builtin latex handler is disabled; a custom handler below renders
        -- inline math only (see comment there). $$ blocks belong to
        -- render-latex.nvim (PNG images in kitty).
        enabled = false,
        converter = "utftex-safe", -- ~/.local/bin/utftex-safe
      },
      -- By default render-markdown hides marks (shows raw source) on the
      -- line the cursor is on ("anti_conceal"), which made inline $math$
      -- look like it never rendered. Always render latex instead.
      anti_conceal = {
        ignore = { latex = true },
      },
    },
    config = function(_, opts)
      -- Why custom: render-markdown's builtin inline branch is unusable with
      -- this markdown parser -- injected latex nodes INCLUDE their $
      -- delimiters, so inline $x$ has dollar-count 2 and the builtin
      -- classifies it as "block" (block=false => 0 marks, verified).
      -- This handler filters on node shape instead: single-line, exactly 2
      -- dollars => inline, convert via utftex-safe (f_0 -> f₀, \mathbb{N} ->
      -- ℕ; braced scripts fall back to latex2text). Everything else ($$...$$,
      -- multi-line) is skipped so render-latex.nvim can image it.
      local pending = {}
      opts.custom_handlers = {
        latex = {
          ---@param ctx { buf: integer, root: TSNode, last: boolean }
          parse = function(ctx)
            local buf = ctx.buf
            if buf and ctx.root then
              local text = vim.treesitter.get_node_text(ctx.root, buf)
              local dollars = select(2, text:gsub("%$", ""))
              if dollars == 2 and not text:find("\n", 1, true) then
                local Node = require("render-markdown.lib.node")
                pending[buf] = pending[buf] or {}
                table.insert(pending[buf], Node.new(buf, ctx.root))
              end
            end
            if not ctx.last then return {} end
            local nodes = pending[buf]
            pending[buf] = nil
            if not nodes or #nodes == 0 then return {} end
            local Context = require("render-markdown.request.context")
            local Marks = require("render-markdown.lib.marks")
            local context = Context.get(buf)
            local config = context.config.latex
            local marks = Marks.new(context, true)
            for _, node in ipairs(nodes) do
              local formula = vim.trim(node.text:match("^%$*(.-)%$*$") or node.text)
              local res = vim.system({ "utftex-safe", formula }, { text = true }):wait()
              local out = (res.stdout or ""):gsub("[\r\n]+$", "")
              if res.code == 0 and out ~= "" then
                marks:over(config, "latex", node, {
                  virt_text = { { out, config.highlight } },
                  virt_text_pos = "inline",
                  conceal = "",
                })
              end
            end
            return marks:get()
          end,
        },
      }
      require("render-markdown").setup(opts)
    end,
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
        inline = false, -- inline math handled by render-markdown (utftex-safe)
        live_preview = true,
      },
    },
    config = function(_, opts)
      -- inline math conceal (and render-markdown) need conceal enabled.
      -- concealcursor="" keeps math rendered even on the cursor line
      -- ("nc" used to un-conceal it, which looked like broken rendering).
      -- To edit raw source: :RenderMarkdown disable  (enable to restore).
      vim.opt.conceallevel = 2
      vim.opt.concealcursor = ""
      -- The theme's Conceal fg (#494D56) is nearly invisible on the dark
      -- background, so concealed sub/superscripts (f_0 -> ₀) looked missing.
      -- Use the math highlight color instead; re-apply after every colorscheme.
      local function fix_conceal_hl()
        vim.api.nvim_set_hl(0, "Conceal", { link = "@markup.math" })
      end
      fix_conceal_hl()
      vim.api.nvim_create_autocmd("ColorScheme", {
        desc = "Make concealed math glyphs visible (theme dims Conceal)",
        callback = fix_conceal_hl,
      })
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
    config = function(_, opts)
      -- image.nvim renders from a deferred callback (render_scheduler). A bulk
      -- edit — `:LineLength reflow`, a paste, an undo — can leave the markdown
      -- treesitter tree holding a range past the end of the buffer, and the next
      -- render then dies inside Neovim's runtime:
      --   vim/treesitter.lua:216: Index out of bounds
      --   (nvim_buf_get_text ← get_node_text ← languagetree.lua _get_injection)
      -- A render frame is idempotent and re-scheduled on the next event, so
      -- dropping the broken one is strictly better than throwing. Upstream
      -- (v1.5.1+22) has no guard here.
      local scheduler = require "image.utils.render_scheduler"
      local schedule = scheduler.schedule
      scheduler.schedule = function(key, callback)
        schedule(key, function()
          local ok, err = pcall(callback)
          if not ok then
            vim.notify("image.nvim: skipped a render frame: " .. tostring(err), vim.log.levels.DEBUG)
          end
        end)
      end
      require("image").setup(opts)
    end,
  },
}
