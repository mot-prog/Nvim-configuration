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

Two ways to keep the text inside the guide
------------------------------------------

`reflow` changes the *file*: the wrap it writes is frozen at the width it was
written at, so a narrower terminal shows long lines again, and the buffer ends
up modified for no better reason than having read it.

*Page mode* changes the *window* instead, and is what reading wants:

  * the text window is made exactly as wide as the limit and the leftover
    columns are parked in an empty window on the right, so the guide and the
    wrap column coincide and text visibly stops at the guide;
  * the buffer is never touched — nothing to undo, save, commit or push;
  * a terminal resize simply re-fits the two windows, so the margin follows the
    window instead of being baked into the text;
  * typing wraps at the guide as well (`wrap` is on and `textwidth` equals the
    window's usable width).

Neovim has no `margin` or `breakat` option, which is why the margin has to be a
window rather than an option. `auto_page` turns it on by itself for
`page_filetypes` (markdown, text, pandoc); `<Leader>uo` / `:LineLength page`
turn it on for the current window in *any* filetype, and switching it off by
hand sticks — `auto_page` will not re-enable it for that window. If something
closes the margin window (`:only`, <C-w>q) it is put back; if something keeps
closing it, page mode gives up on that window.

`shade_margin` (off by default) additionally paints every column past the
limit with the `ColorColumn` highlight, which reads as a real right margin.
Only useful with `wrap = true`: with `wrap = false` text legitimately
continues into that region, so shading would cover what you are reading.

Runtime control: `:LineLength` (status) / `:LineLength 85` / `:LineLength
toggle` / `:LineLength shade` / `:LineLength tw` / `:LineLength typing` (the
typing-wrap flags — not the display option) / `:LineLength page` (display-only
wrap for this window) / `:LineLength reflow` (re-wrap the text already in the
buffer), or `<Leader>uq` to toggle the whole thing and `<Leader>uo` page mode.

Tuning: edit `M.config` below — `percent` (0.95 → try 1.0 to use every column),
`max_limit` (cap it on ultrawide windows), `min_limit` (readability floor for
very narrow splits), `exclude_filetypes` (opt a filetype out of the rule),
`auto_page` / `page_filetypes` / `page_min_margin` (page mode).

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
---@field auto_page boolean open a page filetype in a window and that window becomes the page (display-only)
---@field page_filetypes table<string, true> filetypes `auto_page` applies to
---@field page_min_margin integer do not page a window whose margin would be narrower than this
M.config = {
  percent = 0.95, -- 95% of the usable width; 1.0 = use every last column
  min_limit = 40, -- floor; a window narrower than this simply uses its whole width
  max_limit = nil, -- set e.g. 120 to stop the limit growing on ultrawide windows
  colorcolumn = true,
  shade_margin = false,
  textwidth = true,
  auto_wrap = true, -- without 't'/'c' in 'formatoptions' a set textwidth never wraps typing
  wrap_flags = "tc",
  auto_page = true, -- see the header: page mode wraps the display at the limit, the file is untouched
  page_filetypes = { markdown = true, text = true, pandoc = true },
  page_min_margin = 3,
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

---win -> page state (the page-mode section further down fills this in). Declared
---here because `apply` below needs to know whether a window is a page.
---@type table<integer, PageState>
local page = {}

---Windows the user turned page mode off in by hand; `auto_page` leaves them be.
---@type table<integer, true>
local page_off_by_user = {}

---The width the limit should be computed from. For a page window that is the
---width it would have without its margin window: shrinking the text window to
---the limit must not make the limit shrink again, or page mode would creep
---inwards on every resize.
---@param win integer
---@return integer?
local function effective_width(win)
  local usable = text_width(win)
  if not usable then return nil end
  local st = page[win]
  if st and vim.api.nvim_win_is_valid(st.filler) then
    usable = usable + vim.api.nvim_win_get_width(st.filler)
  end
  return usable
end

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
  local width = effective_width(win)
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
    M.page_fit_all() -- the percentage may have changed: re-balance pages before measuring
    M.apply_all()
  else
    M.page_off_all()
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

-- Page mode -----------------------------------------------------------------
--
-- Hard wrap (`textwidth`, and `:LineLength reflow` for text already in the
-- buffer) changes the *file*: useful, but it leaves the buffer modified, and the
-- wrap it wrote is frozen at the width it was written at.
--
-- Page mode changes the *window* instead. Neovim has no `margin` option, so the
-- only way to make the display wrap at the limit is to make the text window
-- exactly as wide as the limit and park the leftover columns in an empty window
-- on the right. The buffer is never touched — nothing to undo, save or commit —
-- and a terminal resize simply re-fits the two windows, so the margin follows
-- the window instead of being baked into the text.

---@class PageState
---@field filler integer the empty window holding the right margin
---@field wrap boolean the window's 'wrap' before page mode
---@field linebreak boolean idem
---@field smoothscroll boolean idem

-- page_fit changes window widths, which fires WinResized, which calls back in.
local fitting = false

-- Margin windows this module opened. They must never be paged themselves (the
-- `:vsplit` that creates one briefly shows the same buffer in it, which would
-- otherwise look like a window that wants its own margin) and they do not count
-- as "another window is open" when deciding whether to auto-page.
---@type table<integer, true>
local fillers = {}
local making = false

---Real windows sharing `win`'s tab page: not a margin window, not a float.
---(`nvim_list_wins()` spans every tab page, so the tab page has to be filtered.)
---@param win integer
---@return integer
local function real_wins(win)
  local ok, tab = pcall(vim.api.nvim_win_get_tabpage, win)
  if not ok or not tab then return 1 end
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not fillers[w] and vim.api.nvim_win_get_tabpage(w) == tab then
      local ok2, conf = pcall(vim.api.nvim_win_get_config, w)
      if ok2 and conf.relative == "" then n = n + 1 end
    end
  end
  return n
end

---How many windows share `win`'s tab page — closing the last one closes the tab.
---@param win integer
---@return integer
local function tab_wins(win)
  local ok, tab = pcall(vim.api.nvim_win_get_tabpage, win)
  if not ok or not tab then return 1 end
  return vim.fn.tabpagewinnr(tab, "$")
end

---@param win integer
---@param st PageState
local function page_restore(win, st)
  if not vim.api.nvim_win_is_valid(win) then return end
  local wo = vim.wo[win]
  wo.wrap, wo.linebreak, wo.smoothscroll = st.wrap, st.linebreak, st.smoothscroll
end

---@param win integer?
---@return boolean changed
function M.page_off(win)
  win = win or vim.api.nvim_get_current_win()
  local st = page[win]
  if not st then return false end
  page[win] = nil
  page_restore(win, st)
  fillers[st.filler] = nil
  if vim.api.nvim_win_is_valid(st.filler) and tab_wins(st.filler) > 1 then
    pcall(vim.api.nvim_win_close, st.filler, true)
  end
  -- the window just got the margin columns back, so the limit moves: re-apply
  -- now and again once the layout has settled (closing a window widens its
  -- neighbours, and that resize is not always visible yet)
  applied[win] = nil
  apply(win, true)
  vim.schedule(M.apply_all)
  return true
end

---Re-fit one page window: its usable width becomes the limit for the width the
---window *would* have without its margin window, so the margin is always exactly
---`1 - percent` of the space, whatever the terminal is doing.
---@param win integer
---The margin window of a page vanished under us (`:only`, <C-w>q, a plugin
---closing splits). Put it back, but give up if something keeps closing it.
local rebuild_guard = {}
local function rebuild_page(win)
  local now = vim.uv.now()
  local g = rebuild_guard[win]
  if not g or now - g.at > 2000 then
    g = { n = 0, at = now }
    rebuild_guard[win] = g
  end
  g.n = g.n + 1
  if g.n > 3 then
    page_off_by_user[win] = true -- someone is fighting us; stop re-adding the margin
    return
  end
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) and not page[win] and not page_off_by_user[win] then
      M.page_on(win)
    end
  end)
end

local function page_fit(win)
  local st = page[win]
  if not st then return end
  if not vim.api.nvim_win_is_valid(win) then
    page[win] = nil
    return
  end
  if not vim.api.nvim_win_is_valid(st.filler) then
    -- the margin window was closed: put the page's margin back
    page[win] = nil
    fillers[st.filler] = nil
    page_restore(win, st)
    rebuild_page(win)
    return
  end
  local total = effective_width(win)
  if not total then return end
  local delta = limit_for(total) - text_width(win)
  if delta ~= 0 then
    pcall(vim.api.nvim_win_set_width, win, vim.api.nvim_win_get_width(win) + delta)
  end
end

function M.page_fit_all()
  if fitting then return end
  fitting = true
  local wins = {} -- page_fit can drop entries, so iterate a snapshot
  for win in pairs(page) do wins[#wins + 1] = win end
  for _, win in ipairs(wins) do page_fit(win) end
  fitting = false
end

---Turn page mode on for one window.
---@param win integer?
---@return boolean changed
function M.page_on(win)
  win = win or vim.api.nvim_get_current_win()
  if page[win] or skip(win) then return false end
  local usable = text_width(win)
  if not usable then return false end
  if usable - limit_for(usable) < M.config.page_min_margin then return false end

  local wo = vim.wo[win]
  ---@type PageState
  local st = { filler = 0, wrap = wo.wrap, linebreak = wo.linebreak, smoothscroll = wo.smoothscroll }

  local cur = vim.api.nvim_get_current_win()
  local fill, buf
  making = true -- the split below briefly shows this buffer again: do not auto-page it
  local ok = pcall(function()
    vim.api.nvim_set_current_win(win)
    vim.cmd "vsplit"
    fill = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
    vim.api.nvim_win_set_buf(fill, buf)
    local fwo = vim.wo[fill]
    fwo.number, fwo.relativenumber, fwo.signcolumn, fwo.foldcolumn = false, false, "no", "0"
    fwo.colorcolumn, fwo.cursorline, fwo.spell, fwo.wrap = "", false, false, true
    pcall(function() fwo.fillchars = "eob: " end)
    fillers[fill] = true
    pcall(vim.api.nvim_win_set_width, fill, 1) -- hand almost everything back, page_fit rebalances
  end)
  making = false
  if not ok or not fill then
    if fill and vim.api.nvim_win_is_valid(fill) then pcall(vim.api.nvim_win_close, fill, true) end
    vim.api.nvim_set_current_win(cur)
    return false
  end

  st.filler = fill
  page[win] = st
  wo.wrap, wo.linebreak, wo.smoothscroll = true, true, true
  vim.api.nvim_set_current_win(cur)
  page_fit(win)
  return true
end

---@param win integer?
---@return boolean changed
function M.page_toggle(win)
  win = win or vim.api.nvim_get_current_win()
  if page[win] then return M.page_off(win) end
  return M.page_on(win)
end

function M.page_off_all()
  for win in pairs(page) do M.page_off(win) end
end

---@param win integer?
---@return boolean
function M.in_page(win)
  win = win or vim.api.nvim_get_current_win()
  return page[win] ~= nil
end

---A window that should page itself without being asked (filetype-driven).
---@param win integer
---@return boolean
local function auto_page_wanted(win)
  if not M.enabled or not M.config.auto_page or making or fillers[win] or page[win] or skip(win) then
    return false
  end
  -- Only when the document is the whole tab page: a margin window next to every
  -- split would leave nothing to read. `<Leader>uo` pages a window in a split.
  if real_wins(win) > 1 then return false end
  local ft = vim.api.nvim_get_option_value("filetype", { buf = vim.api.nvim_win_get_buf(win) })
  return M.config.page_filetypes[ft] == true
end

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
  local width = effective_width(win) or 0
  local fmt = "line length: %d%% of %d usable → limit %d | tw %s | cc %s | %s | page %s"
  local msg = fmt:format(
    math.floor(M.config.percent * 100 + 0.5),
    width,
    limit_for(width),
    tostring(vim.bo.textwidth),
    vim.wo.colorcolumn == "" and "off" or vim.wo.colorcolumn,
    M.enabled and "on" or "off",
    M.in_page(win) and "on" or "off"
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
    callback = function()
      M.page_fit_all() -- first put the columns back where they belong...
      M.apply_all() -- ...then compute the limit from the resulting widths
    end,
  })

  -- entered a window or buffer → apply to it
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "BufEnter" }, {
    group = augroup,
    desc = "Apply window-relative line limit",
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if auto_page_wanted(win) and not page_off_by_user[win] then M.page_on(win) end
      apply(win)
    end,
  })

  -- FileType fires after the ftplugins have run (this one is registered last),
  -- and those plugins are free to rewrite 'textwidth' and 'formatoptions' — so
  -- force the re-apply rather than trusting the width/buffer cache.
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    desc = "Re-apply line limit after filetype plugins",
    callback = function()
      local win = vim.api.nvim_get_current_win()
      apply(win, true)
      -- The filetype is only reliably known here, so this is where auto-page
      -- fires. Deferred because page_on changes the window layout, which is not
      -- something to do in the middle of a FileType autocommand.
      if auto_page_wanted(win) and not page_off_by_user[win] then
        vim.schedule(function() M.page_on(win) end)
      end
    end,
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
    desc = "Forget a closed window, and clean up page mode around it",
    callback = function(event)
      local win = tonumber(event.match)
      applied[win] = nil
      page_off_by_user[win] = nil
      fillers[win] = nil
      local st = page[win]
      if st then -- the text window itself went away, so its margin has no purpose
        page[win] = nil
        fillers[st.filler] = nil
        if vim.api.nvim_win_is_valid(st.filler) and tab_wins(st.filler) > 1 then
          pcall(vim.api.nvim_win_close, st.filler, true)
        end
      end
      local owned = {}
      for other, oth in pairs(page) do
        if oth.filler == win then owned[#owned + 1] = { other, oth } end
      end
      for _, entry in ipairs(owned) do
        -- the margin window went away (`:only`, <C-w>q): the page wants it back
        page[entry[1]] = nil
        page_restore(entry[1], entry[2])
        rebuild_page(entry[1])
      end
      -- the windows that survived the close are wider now; recompute once the
      -- layout has settled (a close does not always emit a resize event)
      vim.schedule(M.apply_all)
    end,
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
    elseif arg == "page" then
      -- display-only: the window becomes as wide as the limit and the leftover
      -- columns go to an empty window on the right. The buffer is not touched.
      local win = vim.api.nvim_get_current_win()
      if page[win] then
        page_off_by_user[win] = true -- auto_page must not put it back on re-entry
        M.page_off(win)
        echo("line length: page off — full width again")
      elseif M.page_on(win) then
        echo("line length: page on — wraps at the limit, file untouched")
      else
        vim.notify(
          "line length: nothing to page here (window too narrow, or not a normal window)",
          vim.log.levels.WARN
        )
      end
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
      local words = { "status", "on", "off", "toggle", "shade", "tw", "typing", "page", "reflow" }
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
