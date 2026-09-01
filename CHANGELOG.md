# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

#### Overlap compositing

- New option `overflow` controls whether an inline preview may paint outside
  its canvas: `"clip"` (default) crops to the canvas edge; `"visible"` bleeds
  into the surrounding text, skipping cells that have no buffer line/column
  to land on.
- New option `z_order` governs how an inline preview composites where it
  overlaps other cells: `"model"` (default) paints over the colliding cell;
  `"text"` yields the cell to the buffer's content (honoring tab expansion
  and CJK double-width).
- New option `fov` (field of view, default 60) plus `Model:set_fov()`: an
  independent knob from `distance`. Two levels: `default_fov` via `setup()`
  and per-model `fov`.
- New diagnostic `Model:footprint()` and `Model:overflows()` report the
  model's true display range and whether it reaches past the canvas;
  `:WrfmReport` shows `truncated=` and `channel=`.

#### Appearance

- New option `highlight` controls the wireframe color: hex `"#RRGGBB"` for a
  fixed color, or a highlight group name for theme-aware coloring (default
  `"Yellow"`). Runtime setter `wrfm.set_highlight("#00ff88")`.

### Changed

#### Inline rendering

- Inline previews now render through `virt_text` overlay on the host
  buffer's real text lines instead of virtual lines. The source text is
  never pushed or rearranged. **Behavior change**: 0.0.1 inline previews
  pushed buffer content out of the way; now they overlay it.
- `virt_lines_above` model option removed (it only applied to the old push
  channel). The inline anchor is line 0 by default, or the cursor line
  under `only_render_at_cursor`.
- `overflow = "visible"` no longer merely warns and clips; it actually bleeds.

#### Animation and controls

- New option `pause_spin_when_unfocused` (default `true`): a spinning model
  whose host window is not focused stops repainting and resumes instantly
  on refocus. Per-model override via
  `from_file({ pause_spin_when_unfocused = ... })`.

## [0.0.1] - 2026-08-27

Initial release.

### Added

#### Core renderer

- Braille wireframe renderer: 60° FOV perspective projection,
  Cohen-Sutherland clipping, Bresenham rasterization into a 2x4 dot grid —
  byte-identical with `wrfm render --format braille` (verified by golden
  fixtures).
- [`.wrfm`](https://github.com/Vaishnav-Sabari-Girish/wireforge/tree/main/crates/wrfm) parser supporting packed lines, comments and group sections.

#### Viewer modes

- Floating-window viewer (`wrfm://` scratch buffer), anchored-float mode, and
  bound-buffer mode with automatic content restore.
- Inline preview via extmark virtual lines: `:WrfmHere` / `:WrfmDetach` and
  programmatic `wrfm.attach(bufnr)` / `wrfm.detach(bufnr)`. Non-destructive —
  the [`.wrfm`](https://github.com/Vaishnav-Sabari-Girish/wireforge/tree/main/crates/wrfm) source text remains editable.
- Auto-attach for [`*.wrfm`](https://github.com/Vaishnav-Sabari-Girish/wireforge/tree/main/crates/wrfm) buffers via `integrations.wrfm.enabled`.
- Cursor mode (`popup` or `inline`) with `only_render_at_cursor`.
- Insert-mode hide with `clear_in_insert_mode`.

#### Animation and controls

- Auto-spin animation on a libuv timer; `set_spin`, `set_pitch`,
  `set_distance` controls.
- Spin rotates around the model's own (local) Y axis — [wireforge](https://github.com/Vaishnav-Sabari-Girish/wireforge)'s relative
  Space spin — not a world-frame turntable.
- Power-saving lifecycle hooks: spin timers pause on `FocusLost`/`VimSuspend`
  and resume on `FocusGained`/`VimResume`.

#### Registry and management

- Registry API: `wrfm.get_models({window=,buffer=,namespace=})`,
  `wrfm.clear(id?)`, stable model ids, `wrfm.current`.
- Global switch: `wrfm.enable()` / `wrfm.disable()` / `wrfm.is_enabled()`;
  disabled `render()` is a silent no-op returning false.
- `model:hide()` / `model:show()` and module-level `wrfm.hide(id?)` /
  `wrfm.show(id?)`: hide views without unregistering; camera, spin and watch
  state survives the round trip.
- Idempotent creation: `from_file()` with an already-live `options.id`
  returns the existing model instead of registering a duplicate.

#### Hot reload

- Hot reload via directory fs_event (fs_poll fallback) with debouncing,
  mtime/size dedup, warn-once recovery semantics, and `watch=false` opt-out.
- Edit-mode live preview: inline previews attach an `on_lines` buffer watcher,
  so unsaved [`.wrfm`](https://github.com/Vaishnav-Sabari-Girish/wireforge/tree/main/crates/wrfm) edits re-parse and repaint as you type.

#### Commands and diagnostics

- Commands: `:Wrfm [file]`, `:WrfmClear [id]`, `:WrfmList`, `:WrfmHere`,
  `:WrfmDetach`, `:WrfmReport`.
- Diagnostic report (`:WrfmReport`): floating window with Neovim/platform
  info, active configuration, a live snapshot of every registered model.
- Health check (`:checkhealth wrfm`) covering version floor, render/parser/
  timer smoke tests, config summary and CLI advisory.

#### Layout and sizing

- Runtime geometry control: `model:render({ width =, height = })` resizes the
  canvas in place and `model:move(x, y)` repositions a floating window.
- Float placement offsets: `x`/`y` options offset the centered placement at
  creation, `render({ x =, y = })` shifts a live float in place.
- Size-cap surface: `max_width`/`max_height` absolute caps plus
  `max_width_window_percentage` / `max_height_window_percentage` percentage
  caps that clamp derived _and_ explicit sizes.
- `border = false` option: renders a frameless, seamless float (background
  merged into the host window's Normal highlight) for image.nvim look.
- `virt_lines_above` model option: render an inline preview below its anchor
  line instead of above it.

#### Lifecycle management

- Resize adaptation: derived canvas sizes recompute on `VimResized`
  and on `WinResized` for anchored floats.
- Stale-context sweep on `TabEnter`/`BufEnter`/`WinClosed`: models whose float
  was user-closed, whose host buffer was deleted, or whose anchor window
  switched content are torn down automatically.
- Command-line-window guard: `render()` and spin ticks skip while the cmdwin
  is open.
- Deferred first render: a programmatic `render()` before the UI exists waits
  for `VimEnter` so terminal dimensions are known.
- Non-focusable viewer floats so keys always stay in the host window.

#### Infrastructure

- Shipped `ftdetect/wrfm.lua`: opening a [`.wrfm`](https://github.com/Vaishnav-Sabari-Girish/wireforge/tree/main/crates/wrfm) file sets `filetype=wrfm`.
- Vimdoc (`doc/wrfm.txt`) covering setup, API, commands, inline preview, hot
  reload and lifecycle; Chinese interactive test guide under `docs/`.
- Zero-dependency test suite run with `nvim -l tests/busted.lua` (busted via
  lazy.minit), golden oracle fixtures, e2e/api/parser/renderer/inline suites;
  mise tasks for format, tests and local act CI.
- CI: Neovim stable/nightly matrix plus stylua format job.
- EmmyLua type annotations across all modules.
- MIT license.
