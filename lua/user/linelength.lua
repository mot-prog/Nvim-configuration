--[[
Window-relative line length — for EVERY filetype (.md, .java, .c, ...).

The idea: the line limit is not a fixed column count (80/100/120) but a
percentage of the *usable text width of the window*, i.e. the window width
minus the gutters that eat it (number column, sign column, fold column).
Widen a split and the limit grows with it, narrow it and the limit shrinks,
so the text always fills the window instead of stopping at an arbitrary 80.

Neovim has no native "render width" option, so the percentage is expressed
through the two options that do exist:

  * `colorcolumn` — window-local vertical guide, drawn one column past the limit
  * `textwidth`   — buffer-local wrap/format width, so `gq`, `gw` and typing
                    auto-wrap stop at exactly the same column as the guide

Both are recomputed on resize, on window/buffer switches, and whenever a
gutter option (number, signcolumn, foldcolumn, …) changes.

What `textwidth` does — and what it does NOT, which is the usual source of
"the guide moved but the text did not":

  * It wraps *typed* text at the limit, but only when 'formatoptions' carries
    't' (typed text) and 'c' (comments). Several filetypes — c, java, lua,
    vim among them — load without those flags, so `auto_wrap` below adds them
    per buffer. Without them `textwidth` is set but typing runs straight
    through the guide.
  * It never re-wraps text that is already in the buffer, and it never moves
    the guide's effect onto existing lines. Reflow is a deliberate act:
    `:LineLength reflow` re-wraps the whole buffer (or just the visual
    selection / `:12,40LineLength reflow`), one paragraph at a time, and `u`
    undoes it. See `reflow_lines` below for what it refuses to touch.
  * With the AstroNvim default `wrap = false` a line longer than the window is
    not displayed wrapped at all — it scrolls sideways past the guide. Set
    `:set wrap` if you want the display to break too (at the window edge, not
    at the guide: Neovim has no display-width option below the window width).

`shade_margin` (off by default) additionally paints every column past the
limit with the `ColorColumn` highlight, which reads as a real right margin.
Only useful with `wrap = true`: with `wrap = false` text legitimately
continues into that region, so shading would cover what you are reading.

Runtime control: `:LineLength` (status) / `:LineLength 85` / `:LineLength
toggle` / `:LineLength shade` / `:LineLength tw` / `:LineLength typing` (the
typing-wrap flags — not the display option) / `:LineLength reflow` (re-wrap the
text already in the buffer), or `<Leader>uq` to toggle the whole thing.

Tuning: edit `M.config` below — `percent` (0.95 → try 1.0 to use every column),
`max_limit` (cap it on ultrawide windows), `min_limit` (readability floor for
very narrow splits), `exclude_filetypes` (opt a filetype out of the rule).

Caveat: `textwidth` is buffer-local, so if the *same* buffer is open in two
windows of different widths, `colorcolumn` is correct in both but `textwidth`
follows whichever window was applied last. Two different buffers, two
different windows, are independent and both correct.
]]

local M = {}

---@class LineLengthConfig
---@field percent number fraction of the usable window text width used as the limit
---@field min_limit integer never compute a limit below this many columns
---@field max_limit integer? never compute a limit above this many columns (nil = no cap)
---@field colorcolumn boolean draw the vertical guide one column past the limit
---@field shade_margin boolean shade every column past the limit (only sensible with wrap = true)
---@field textwidth boolean set buffer-local `textwidth` to the limit (gq / autoformat / typing)
---@field auto_wrap boolean make `textwidth` wrap while typing by adding `wrap_flags` to 'formatoptions'
---@field wrap_flags string the 'formatoptions' flags `auto_wrap` adds: t = typed text, c = comments
---@field exclude_filetypes table<string, true> filetypes to leave untouched
M.config = {
  percent = 0.95, -- 95% of the usable width; 1.0 = use every last column
  min_limit = 40, -- floor; a window narrower than this simply uses its whole width
  max_limit = nil, -- set e.g. 120 to stop the limit growing on ultrawide windows
  colorcolumn = true,
  shade_margin = false,
  textwidth = true,
  auto_wrap = true, -- without 't'/'c' in 'formatoptions' a set textwidth never wraps typing
  wrap_flags = "tc",
  exclude_filetypes = {
    -- deliberately fixed-width conventions; uncomment to opt out of the window rule
    -- gitcommit = true,
  },
}

M.enabled = true

---Usable text columns of a window: window width minus the gutters drawn inside it.
---@param win integer
---@return integer?
local function text_width(win)
  local ok, width = pcall(vim.api.nvim_win_get_width, win)
  if not ok then return nil end
  local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok_buf then return nil end

  local wo = vim.wo[win]
  if wo.number or wo.relativenumber then width = width - wo.numberwidth end

  local signcolumn = wo.signcolumn
  if signcolumn:find "number" then
    -- signs share the number column, which was already subtracted
  elseif signcolumn == "yes" then
    width = width - 2
  elseif signcolumn == "auto" then
    local ok_placed, placed = pcall(vim.fn.sign_getplaced, buf)
    if ok_placed and placed[1] and #(placed[1].signs or {}) > 0 then width = width - 2 end
  end

  width = width - (tonumber(wo.foldcolumn) or 0)
  return math.max(width, 1)
end

---Should this window be left alone? (floats, help, terminals, quickfix, opted-out filetypes)
---@param win integer
---@return boolean
local function skip(win)
  local ok, conf = pcall(vim.api.nvim_win_get_config, win)
  if not ok or conf.relative ~= "" then return true end -- floating window
  local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok_buf then return true end
  if vim.api.nvim_get_option_value("buftype", { buf = buf }) ~= "" then return true end
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  return M.config.exclude_filetypes[ft] == true
end

---The line limit for a given usable width, in columns.
---@param width integer
---@return integer
local function limit_for(width)
  local limit = math.floor(width * M.config.percent + 0.5)
  if M.config.max_limit then limit = math.min(limit, M.config.max_limit) end
  limit = math.max(limit, M.config.min_limit)
  return math.min(limit, width) -- never wider than the window itself
end

---win -> { width, buf } last applied. Lets the high-frequency events below be a
---cheap no-op until something actually changed.
---@type table<integer, { width: integer, buf: integer }>
local applied = {}

---buf -> the 'formatoptions' flags this module added there, so they can be
---taken back out instead of leaking into the buffer.
---@type table<integer, string>
local added_flags = {}

---Make 'formatoptions' carry exactly the wrap flags the current config wants.
---'t' wraps typed text at 'textwidth', 'c' does the same inside comments — a
---filetype that loads without them (c, java, lua, vim among them) otherwise
---ignores the `textwidth` set above, which is what makes the guide look inert.
---@param buf integer
local function sync_wrap_flags(buf)
  local want = (M.enabled and M.config.textwidth and M.config.auto_wrap) and M.config.wrap_flags
    or ""
  local before = vim.api.nvim_get_option_value("formatoptions", { buf = buf })
  -- take back exactly the flags added last time, never one the buffer had itself
  local fo = before
  for flag in (added_flags[buf] or ""):gmatch "." do fo = fo:gsub(flag, "", 1) end
  local missing = {}
  for flag in want:gmatch "." do
    if not fo:find(flag, 1, true) then missing[#missing + 1] = flag end
  end
  added_flags[buf] = table.concat(missing)
  local now = fo .. table.concat(missing)
  if now ~= before then vim.api.nvim_set_option_value("formatoptions", now, { buf = buf }) end
end

---Apply the guide + `textwidth` to one window (and the buffer shown in it).
---@param win integer
---@param force? boolean re-apply even if width and buffer are unchanged (after ftplugins ran)
local function apply(win, force)
  if not M.enabled or skip(win) then return end
  local width = text_width(win)
  if not width then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local seen = applied[win]
  if not force and seen and seen.width == width and seen.buf == buf then return end
  applied[win] = { width = width, buf = buf }
  local limit = limit_for(width)

  if M.config.colorcolumn then
    if M.config.shade_margin then
      local cols = {}
      for col = limit + 1, width do cols[#cols + 1] = col end
      vim.wo[win].colorcolumn = table.concat(cols, ",")
    else
      vim.wo[win].colorcolumn = tostring(limit + 1)
    end
  end

  if M.config.textwidth then
    vim.api.nvim_set_option_value("textwidth", limit, { buf = buf })
  end
  sync_wrap_flags(buf)
end

---Apply to every window of every tab page.
function M.apply_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do apply(win) end
end

---Re-apply (or clear) after a config change.
function M.refresh()
  applied = {} -- config changed, the cached widths no longer describe the result
  if M.enabled then
    M.apply_all()
  else
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if not skip(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        vim.wo[win].colorcolumn = ""
        vim.api.nvim_set_option_value("textwidth", 0, { buf = buf })
        sync_wrap_flags(buf) -- takes back the flags it had added
      end
    end
  end
end

---@param on boolean
function M.enable(on)
  M.enabled = on and true or false
  M.refresh()
end

function M.toggle() M.enable(not M.enabled) end

---Set the percentage. Values above 1 are read as percentage points (`85` == `0.85`).
---@param n number
function M.set_percent(n)
  local pct = n > 1 and n / 100 or n
  M.config.percent = math.min(math.max(pct, 0.05), 1)
  M.enabled = true -- asking for a percentage means wanting the limit
  M.refresh()
  M.status()
end

---Echo the current limit for the current window.
function M.status()
  local win = vim.api.nvim_get_current_win()
  local width = text_width(win) or 0
  local fmt = "line length: %d%% of %d usable cols (win %d)"
    .. " → limit %d | textwidth %s | colorcolumn %s | %s"
  local msg = fmt:format(
    math.floor(M.config.percent * 100 + 0.5),
    width,
    vim.api.nvim_win_get_width(win),
    limit_for(width),
    tostring(vim.bo.textwidth),
    vim.wo.colorcolumn == "" and "off" or vim.wo.colorcolumn,
    M.enabled and "on" or "off"
  )
  vim.api.nvim_echo({ { msg, "Normal" } }, false, {})
end

local function register_autocmds(augroup)
  -- the terminal or a window changed size, or a window appeared/disappeared
  -- (which changes the width of the others too) → recompute everywhere
  local layout_events = {
    "VimResized", "WinResized", "WinNew",
    "WinClosed", "TabNewEntered", "SessionLoadPost",
  }
  vim.api.nvim_create_autocmd(layout_events, {
    group = augroup,
    desc = "Recompute line limit for every window after a layout change",
    callback = M.apply_all,
  })

  -- entered a window or buffer → apply to it
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "BufEnter" }, {
    group = augroup,
    desc = "Apply window-relative line limit",
    callback = function() apply(vim.api.nvim_get_current_win()) end,
  })

  -- FileType fires after the ftplugins have run (this one is registered last),
  -- and those plugins are free to rewrite 'textwidth' and 'formatoptions' — so
  -- force the re-apply rather than trusting the width/buffer cache.
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    desc = "Re-apply line limit after filetype plugins",
    callback = function() apply(vim.api.nvim_get_current_win(), true) end,
  })

  -- a gutter appeared/disappeared → the usable width changed
  vim.api.nvim_create_autocmd("OptionSet", {
    group = augroup,
    pattern = "number,relativenumber,numberwidth,signcolumn,foldcolumn",
    desc = "Recompute line limit after a gutter change",
    callback = M.apply_all,
  })

  -- `WinResized` is only emitted after a display update, so a resize that happens
  -- without one is missed. This catches it; it stays cheap because apply()
  -- returns immediately while the cached width + buffer still match.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    desc = "Catch a window resize that produced no resize event",
    callback = function() apply(vim.api.nvim_get_current_win()) end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    desc = "Forget the cached layout of a closed window",
    callback = function(event) applied[tonumber(event.match)] = nil end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    desc = "Forget the formatoptions flags added to a deleted buffer",
    callback = function(event) added_flags[event.buf] = nil end,
  })
end

---Line starts that must never be re-wrapped, per filetype. Plain `gq` will
---happily snap a markdown heading in half — and insert a blank line while doing
---it — which is what makes a reflow look like it "did something strange".
---@type table<string, string[]>
local PROTECTED = {
  markdown = { "^%s*# ", "^%s*#%S", "^%s*|", "^%s*%[%[", "^%s*!%[" },
  pandoc = { "^%s*# ", "^%s*#%S", "^%s*|" },
  help = { "^%s*%*%S", "^%s*=%s*$" },
}

---Which lines sit inside a fenced code block (or YAML front matter).
---@param lines string[]
---@return boolean[]
local function fenced(lines)
  local inside, open = {}, false
  for n, line in ipairs(lines) do
    if line:match "^%s*```" or line:match "^%s*~~~" then
      inside[n], open = true, not open
    else
      inside[n] = open
    end
  end
  if lines[1] and lines[1]:match "^%-%-%-%s*$" then
    for n = 2, #lines do
      inside[n] = true
      if lines[n]:match "^%-%-%-%s*$" or lines[n]:match "^%.%.%.$" then break end
    end
  end
  return inside
end

---@param patterns string[]?
---@param line string
---@return boolean
local function protected_line(patterns, line)
  if not patterns then return false end
  for _, p in ipairs(patterns) do
    if line:match(p) then return true end
  end
  return false
end

---Re-wrap the text in [l1, l2] to the buffer's `textwidth`, one paragraph block
---at a time. `gq` is an operator, not an Ex command in Neovim (`:2,4gq` is E492),
---so each block is driven through a visual selection. Blocks are walked
---bottom-up, because re-wrapping one changes the line numbers of everything
---below it but never of what is still to come.
---@param l1 integer
---@param l2 integer
---@return integer reformatted, integer left_alone
local function reflow_lines(l1, l2)
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local fence = fenced(lines)
  local protect = PROTECTED[vim.bo[buf].filetype]
  local reformatted, left = 0, 0

  local n = math.min(l2, #lines)
  while n >= l1 do
    local line = lines[n]
    if not line or line:match "^%s*$" then
      n = n - 1
    else
      local top, skip_block = n, fence[n] or protected_line(protect, line)
      while top > l1 and top > 1 and not lines[top - 1]:match "^%s*$" and not fence[top - 1] do
        top = top - 1
        if fence[top] or protected_line(protect, lines[top]) then skip_block = true end
      end
      if skip_block then
        left = left + (n - top + 1)
      else
        -- one undo step for the whole reflow, not one per paragraph
        if reformatted > 0 then vim.cmd "undojoin" end
        vim.cmd(string.format("keepjumps normal! %dGV%dGgq", top, n))
        reformatted = reformatted + (n - top + 1)
      end
      n = top - 1
    end
  end
  return reformatted, left
end

local function register_command()
  local function echo(msg) vim.api.nvim_echo({ { msg, "Normal" } }, false, {}) end
  vim.api.nvim_create_user_command("LineLength", function(opts)
    local arg = (opts.args or ""):gsub("%s+", ""):lower()
    local number = tonumber(arg)
    if arg == "" or arg == "status" then
      M.status()
    elseif arg == "on" then
      M.enable(true)
    elseif arg == "off" then
      M.enable(false)
    elseif arg == "toggle" then
      M.toggle()
    elseif arg == "shade" then
      M.config.shade_margin = not M.config.shade_margin
      M.refresh()
      echo("line length: right-margin shading " .. (M.config.shade_margin and "on" or "off"))
    elseif arg == "tw" then
      M.config.textwidth = not M.config.textwidth
      M.refresh()
      echo("line length: textwidth " .. (M.config.textwidth and "on" or "off"))
    elseif arg == "typing" or arg == "wrap" then
      -- 'formatoptions' flags that make textwidth wrap while typing. Not the
      -- display option `wrap`: this is about the text, not about how the window
      -- renders an over-long line.
      M.config.auto_wrap = not M.config.auto_wrap
      M.refresh()
      echo("line length: wrap while typing (" .. M.config.wrap_flags .. " in formatoptions) "
        .. (M.config.auto_wrap and "on" or "off") .. " — for display use :set wrap")
    elseif arg == "reflow" then
      -- `textwidth` never touches text that is already in the buffer, so
      -- re-wrapping it is a deliberate act. No range = the whole buffer, which
      -- is what typing the command yourself means; a visual selection or an
      -- explicit range narrows it. `u` undoes the whole thing.
      local l1, l2 = 1, vim.api.nvim_buf_line_count(0)
      if opts.range > 0 then l1, l2 = opts.line1, opts.line2 end
      if vim.bo.textwidth < 1 then
        vim.notify("line length: this buffer has no limit set, so there is nothing to reflow to", vim.log.levels.WARN)
      elseif l2 - l1 + 1 > 1000 then
        vim.notify(
          "line length: " .. (l2 - l1 + 1) .. " lines is too many to reflow blindly, select a range first",
          vim.log.levels.WARN
        )
      else
        local done, left = reflow_lines(l1, l2)
        echo(string.format(
          "line length: reflowed %d line(s) to %d columns, %d left alone (headings, code, tables) — u undoes it",
          done,
          vim.bo.textwidth,
          left
        ))
      end
    elseif number then
      M.set_percent(number)
    else
      vim.notify(
        "LineLength: expected a percentage, got " .. vim.inspect(arg),
        vim.log.levels.WARN
      )
    end
  end, {
    nargs = "?",
    range = true, -- `:LineLength reflow` accepts a range / visual selection
    desc = "Line limit as a percentage of the window width",
    complete = function(arglead)
      local words = { "status", "on", "off", "toggle", "shade", "tw", "typing", "reflow" }
      return vim.tbl_filter(function(w) return w:match "^" .. vim.pesc(arglead) end, words)
    end,
  })
end

---Install the feature (idempotent).
---@param opts LineLengthConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if M._installed then
    M.refresh()
    return
  end
  M._installed = true
  register_autocmds(vim.api.nvim_create_augroup("UserLineLength", { clear = true }))
  register_command()
  M.apply_all()
end

return M
