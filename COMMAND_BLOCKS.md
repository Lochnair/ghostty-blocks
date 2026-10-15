# Command blocks: Milestone 1

Enable command blocks in your Ghostty configuration:

```ini
command-blocks = true
```

Shell integration must emit OSC 133. Markers use existing left window padding
and never change terminal columns. With less than four physical pixels of left
padding, markers are hidden. Increase the existing `window-padding-x` setting
if you want a larger gutter; changing that setting has its ordinary sizing
effect independently of command blocks.

Click the left padding beside a command to select its block. The selected marker
is blue and wider when padding allows. Other marker colors distinguish running commands, successful
commands, failures, and interactions with unknown status. Markers stop at the
written interaction; unused space below it is not a selectable block.

- Cmd+C copies a selected block's command and output, excluding prompts.
- Ordinary text selection takes precedence over block selection.
- Clicking or dragging terminal text returns to ordinary text selection, which
  can cross command boundaries.
- Escape clears block selection. Typing clears it and forwards input normally.
- Alternate-screen programs use Ghostty's ordinary rendering and input handling.

The command palette also contains Copy Command, Copy Command Output, Copy
Command Block, and Copy Command Working Directory. These actions use the
selected block, or the most recent executed command when no block is selected.
They can be bound explicitly, for example:

```ini
keybind = super+shift+c=copy_block:command
keybind = super+shift+o=copy_block:output
keybind = super+shift+b=copy_block:block
keybind = super+shift+w=copy_block:cwd
```

These example bindings are optional; the feature does not replace existing
shortcuts. `copy_block` without a parameter defaults to `block`.

## Clipboard behavior

Soft wraps are joined; hard line breaks and output blank lines are preserved.
Continuation prompts are excluded from commands. Existing trailing-space and
clipboard codepoint-map settings apply to buffer extraction. Empty results leave
the clipboard unchanged. Working directories are captured when execution starts,
with the prompt-time directory as a fallback.

Copying captures one page at a time, releases terminal access, and uses the
upstream formatter on the owned snapshot. Output has no fixed-size truncation.
Reflow, reset, or eviction of a copy request's boundaries cancels that request
rather than publishing a truncated result. A running command's append-only
output is bounded at the time copying starts; concurrently overwritten content
is captured page by page, rather than as an atomic PTY transcript.

Missing semantic events retain unknown/incomplete state. Component copying is
limited to boundaries actually available. Enabling the feature after commands
have run discovers their semantic prompt rows, but cannot recover their historic
exit status, directory, or OSC execution fences. Enable it before starting the
shell for complete metadata. Scrollback eviction can leave a partial output
block whose original prompt/command is unavailable.

## Implementation boundaries

- `terminal/CommandBlocks.zig` owns optional primary-screen metadata and the
  shared block-ID/content-type extraction request.
- Upstream remains responsible for OSC interpretation, semantic cells, tracked
  pin relocation, reflow, selection, and text encoding.
- `renderer/BlockMarkers.zig` exports a pointer-free viewport marker snapshot
  and shares the gutter hit-test geometry with Surface.
- Production markers use the existing image pipeline; inspector overlays remain
  separate. There is no projected viewport, virtual spacing, collapse, filter,
  toolbar, or new scrolling behavior in this milestone.
- Native Copy validation includes block selection through a separate capability
  query, preserving the existing text-only selection/accessibility APIs.

## Validation

Targeted tests cover semantic extraction, empty and live commands, Unicode,
wraps, multiline prompts/input, large output, eviction, reflow/redraw, reset,
compression, alternate-screen isolation, ordinary cross-block selection, gutter
coordinates, and binding parsing. Run tests using the repository's supported Zig
version, preferably with `-Dtest-filter`.

Before considering the macOS interaction validated, build on macOS using
`zig build -Demit-macos-app=false` and `macos/build.nu`, then check:

1. zsh commands with zero output, multiline input, Unicode, blank lines, and
   thousands of output lines; fish/bash where available.
2. Gutter selection and Cmd+C versus ordinary word/line/drag selection, links,
   prompt clicking, and copying into a plain-text editor.
3. Window/font resizing while editing and producing output, substantial history,
   and scrollback eviction.
4. Neovim, less, and htop/btop on the alternate screen, followed by return to zsh.
5. Zero/narrow/wide padding, display scaling, runtime enable/disable, and unchanged
   terminal columns when toggling `command-blocks`.

Extensive performance benchmarks, native block context menus, and multi-block
selection remain later milestones.
