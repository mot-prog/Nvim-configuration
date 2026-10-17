# linelength — status

Module: [lua/user/linelength.lua](linelength.lua) (~820 lines), wired from
[lua/plugins/astrocore.lua](../plugins/astrocore.lua) (`VimEnter` → `setup()`, mappings `<Leader>uq`
toggle the limit, `<Leader>uo` toggle page mode, command `:LineLength`).

The three items requested (m00535) are **implemented and verified**. What is left is optional polish.

## Done

- [x] **1. Non-destructive viewing — page mode.** Neovim 0.12 has no `margin`/`breakat` option
      (verified: `E518: Unknown option`), so the margin is made a *window*: the text window is
      resized to exactly the limit and the leftover columns are parked in an empty filler window on
      the right (`bufhidden=wipe`, `winfixwidth`, no filetype, skipped by `skip()`). `wrap` +
      `linebreak` + `smoothscroll` are set on the text window, `textwidth` equals its usable width,
      so typing wraps at the guide too. The buffer is never modified — nothing to undo, save, commit
      or push. `auto_page = true` turns it on for `page_filetypes` (`markdown`, `text`, `pandoc`);
      `<Leader>uo` / `:LineLength page` turn it on for the current window in any filetype, and a
      manual off sticks.
      Config: `auto_page`, `page_filetypes`, `page_min_margin`.
- [x] **2. Resize behaviour.** Page mode re-fits on every layout change: pty (TIOCSWINSZ) 120x40 →
      text 113 + margin 6, `tw=106 cc=107`; 60x20 → `tw=50 cc=51`; back to 120 → restored.
      `:split` / `:only` / `:tabedit` / `<Leader>uq` off-on all keep the two windows consistent; if
      `:only` or `<C-w>q` closes the margin it is rebuilt (and page mode gives up on a window that
      something keeps closing). `<Leader>uo` verified by real keystrokes in a pty TUI.
- [x] **3. The image.nvim `Index out of bounds` crash.** Cause: image.nvim's markdown integration
      reads stale treesitter node ranges after a bulk edit (`:LineLength reflow`, paste, undo) —
      `nvim_buf_get_text` ← `get_node_text` ← `languagetree.lua _get_injection` →
      `vim/treesitter.lua:216: Index out of bounds`. Installed version is already current
      (v1.5.1+22, 2026-09-05) and has no guard. Fix: `lua/plugins/markdown.lua` now wraps
      `require("image.utils.render_scheduler").schedule` so each render frame runs under `pcall` —
      a broken frame is dropped (logged at DEBUG) instead of throwing; the next event re-renders.
      Control test: an unshimmed `vim.schedule` error prints exactly the reported message form; with
      the shim nothing surfaces. (The treesitter bug itself needs a kitty-capable terminal to
      reproduce, so it could not be triggered headlessly here.)

## Notes for future work

- `reflow` still exists and is still range-aware (`gq{top}GV{n}Ggq` per paragraph block, bottom-up,
  `:undojoin` → one `u` undoes it all, protected: headings, `---` front matter, tables, fenced code,
  `[url]:` definitions). Page mode is the default way to *read*; `reflow` is only for when you want
  the wrap frozen into the file.
- `textwidth` is buffer-local: the same buffer in two windows of different widths follows the last
  window applied; `colorcolumn` is per-window and always correct.
- Format-on-save is active (`lua/plugins/astrolsp.lua:20`): none-ls → stylua + prettier +
  clang-format. Prettier re-aligns markdown tables on save but does not unwrap reflowed prose
  (`proseWrap: preserve`). `.stylua.toml`: `column_width=120`, 2-space indent,
  `collapse_simple_statement="Always"`; stylua is not installed on this box, so format by hand.
- Test harness rules (learned the hard way): everything inside the workspace; run nvim with
  `XDG_CACHE_HOME`/`XDG_STATE_HOME` pointed at workspace dirs (`/tmp` and `~/.cache` are read-only
  here → `E5111: EROFS`); real-UI tests need a `pty.fork` driver that answers nvim's startup terminal
  queries (`\x1b[?64;1;2;6;18;21;22c\x1b]11;rgb:0000/0000/0000\x1b\\\x1b[0n`) after ~6 s, then sends
  commands with `\r`; never name the script `pty.py`; headless nvim fires no resize/cursor events, so
  resize behaviour can only be tested through the pty.
- Optional, not done: a floating "page" window instead of the filler split (prettier, but floats are
  excluded by `skip()` and completion behaves differently in them); a `view = "hard" | "page"`
  per-filetype table instead of the `auto_page` + `page_filetypes` pair; shading the margin
  (`shade_margin`) in page mode.
