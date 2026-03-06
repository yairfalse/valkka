# Valkka: UI/UX Design

> Terminal-born. AI-native. Keyboard-first.
> Not a git GUI with AI bolted on. A command center that happens to show git.

---

## 1. Design Philosophy

1. **Terminal-inspired, not terminal-limited.** Monospace everywhere. Information-dense. But with the rendering power of a real app — graphs, syntax highlighting, smooth animations.
2. **Keyboard-first, mouse-optional.** Every action reachable via keyboard. Vim-style navigation. Command palette for discovery.
3. **Dark by default.** Not "supports dark mode" — IS dark mode. Light mode is not planned.
4. **Sharp, not soft.** Square corners (max 2px radius). No gradients on surfaces. No drop shadows on cards. Clean lines, hard edges.
5. **Information density over whitespace.** Show more, scroll less. Developers read dense UIs — don't dumb it down.
6. **Chat is the primary interface.** The graph, diff, and review views are tools the chat can invoke. Not tabs you browse.

---

## 2. Color System

```css
:root {
  /* Backgrounds */
  --bg-root:            #0a0a0f;    /* app background, near black with blue tint */
  --bg-surface:         #12121a;    /* panels, cards */
  --bg-surface-hover:   #1a1a25;    /* hover state */
  --bg-surface-active:  #22222e;    /* selected/active state */
  --bg-elevated:        #16161f;    /* modals, command palette */
  --bg-input:           #0e0e16;    /* input fields */

  /* Borders */
  --border-default:     #2a2a35;
  --border-subtle:      #1e1e28;
  --border-focus:       #00ff88;

  /* Text */
  --text-primary:       #e0e0e8;    /* main text */
  --text-secondary:     #9a9aa8;    /* labels, metadata */
  --text-muted:         #5a5a68;    /* decorative, timestamps */
  --text-inverse:       #0a0a0f;    /* text on accent backgrounds */

  /* Accent — neon green, the brand */
  --accent:             #00ff88;
  --accent-hover:       #00cc6e;
  --accent-ghost:       #00ff8815;  /* 8% opacity, for backgrounds */
  --accent-dim:         #00ff8840;  /* 25% opacity */

  /* Status */
  --status-success:     #00ff88;
  --status-warning:     #ffaa00;
  --status-error:       #ff4466;
  --status-info:        #4488ff;

  /* Diff */
  --diff-add-bg:        #00ff8812;  /* green, 7% opacity */
  --diff-add-text:      #00ff88;
  --diff-remove-bg:     #ff446612;  /* red, 7% opacity */
  --diff-remove-text:   #ff4466;
  --diff-hunk-header:   #4488ff20;

  /* Graph — 8 branch colors that cycle */
  --branch-0:           #00ff88;    /* green (main) */
  --branch-1:           #4488ff;    /* blue */
  --branch-2:           #ff6644;    /* orange */
  --branch-3:           #cc44ff;    /* purple */
  --branch-4:           #ffaa00;    /* amber */
  --branch-5:           #00ddcc;    /* teal */
  --branch-6:           #ff4488;    /* pink */
  --branch-7:           #88cc00;    /* lime */
}
```

---

## 3. Typography

```css
:root {
  --font-mono:          'Berkeley Mono', 'JetBrains Mono', 'Fira Code', monospace;
  --font-size-xs:       11px;
  --font-size-sm:       12px;
  --font-size-base:     14px;
  --font-size-lg:       16px;
  --font-size-xl:       20px;
  --font-size-2xl:      24px;

  --font-weight-normal: 400;
  --font-weight-medium: 500;
  --font-weight-bold:   600;

  --line-height-tight:  1.3;   /* compact lists, sidebar */
  --line-height-normal: 1.5;   /* body text, chat */
  --line-height-code:   1.6;   /* code blocks, diffs */

  --tracking-tight:     -0.02em;  /* headings */
  --tracking-normal:    0;        /* body */
}
```

**Rules:**
- Everything is monospace. No sans-serif anywhere.
- Headings: weight 600, tracking tight
- Body: weight 400, 14px
- Code: same font, different color (--text-secondary for non-highlighted)
- Labels/categories: weight 500, uppercase, --font-size-xs, --text-muted

---

## 4. Spacing

```css
:root {
  --space-1:  4px;
  --space-2:  8px;
  --space-3:  12px;
  --space-4:  16px;
  --space-5:  20px;
  --space-6:  24px;
  --space-8:  32px;
  --space-10: 40px;
  --space-12: 48px;
}
```

- Panel padding: --space-4
- Card padding: --space-3
- List item padding: --space-2 vertical, --space-3 horizontal
- Section gaps: --space-6

---

## 5. Layout System

```
┌─ status bar (24px) ─────────────────────────────────────────────────┐
├─────────┬─ tab bar ─────────────────────────────────┬───────────────┤
│         │  [Chat]  [Graph]  [Diff]  [PR]            │               │
│ SIDEBAR │─────────────────────────────────────────────│ CONTEXT      │
│ 240px   │                                            │ PANEL        │
│         │              MAIN PANEL                    │ 320px        │
│ repos   │              (active view)                 │              │
│ list    │                                            │ AI context   │
│         │                                            │ commit info  │
│ branch  │                                            │ file info    │
│ list    │                                            │              │
│         │                                            │              │
│         ├────────────────────────────────────────────┤              │
│ quick   │  > command input                           │              │
│ status  │                                            │              │
├─────────┴────────────────────────────────────────────┴──────────────┤
│ status: ● valkka main clean  │  AI: Claude Sonnet 4  │  Cmd+K help  │
└─────────────────────────────────────────────────────────────────────┘
```

### Panel Rules

| Panel | Width | Collapsible | Shortcut |
|---|---|---|---|
| Sidebar | 240px default, 160-400px range | Yes (Cmd+B) | Cmd+B |
| Main | flex (fills remaining) | No | — |
| Context | 320px default, 200-500px range | Yes (Cmd+.) | Cmd+. |

- Resize handles: 4px hover zone, cursor changes to `col-resize`
- Double-click handle: collapse/expand
- Collapsed state: 0px width, icon-only toggle button remains

### Status Bar (Top, 24px)

```
┌─────────────────────────────────────────────────────────────────────┐
│  Valkka  │  ~/projects  │  ● valkka (main)  │  3 repos  │  ◐ 2 dirty │
└─────────────────────────────────────────────────────────────────────┘
```

### Footer Bar (Bottom, 24px)

```
┌─────────────────────────────────────────────────────────────────────┐
│  ● Connected  │  AI: Claude Sonnet 4  │  Cmd+K commands  │  v0.1.0 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. Dashboard View (Multi-Repo Overview)

Default view when no repo is focused.

```
┌─────────┬───────────────────────────────────────────────────────────┐
│ REPOS   │  WORKSPACE: ~/projects                                    │
│         │                                                           │
│ > valkka │  ┌─────────────────────────┐  ┌─────────────────────────┐ │
│   false │  │ ● valkka                 │  │ ◐ false-protocol        │ │
│   kerto │  │   main                  │  │   feat/v2               │ │
│   sykli │  │   clean                 │  │   3 files modified      │ │
│         │  │   CI: ✓ all passing     │  │   CI: ✕ test failed     │ │
│         │  │   last: 2m ago          │  │   last: 15m ago         │ │
│         │  │   [commit] [graph]      │  │   [commit] [graph]      │ │
│         │  └─────────────────────────┘  └─────────────────────────┘ │
│         │                                                           │
│         │  ┌─────────────────────────┐  ┌─────────────────────────┐ │
│         │  │ ● kerto                 │  │ ● sykli                 │ │
│         │  │   main                  │  │   main                  │ │
│         │  │   clean                 │  │   clean                 │ │
│         │  │   CI: ✓ all passing     │  │   CI: ✓ all passing     │ │
│         │  │   last: 1h ago          │  │   last: 3h ago          │ │
│         │  │   [commit] [graph]      │  │   [commit] [graph]      │ │
│         │  └─────────────────────────┘  └─────────────────────────┘ │
│         │                                                           │
│         ├───────────────────────────────────────────────────────────┤
│         │  > what needs attention?                                   │
└─────────┴───────────────────────────────────────────────────────────┘
```

### Card States

- **Clean**: `●` green dot, `--border-subtle` border
- **Dirty**: `◐` amber dot, `--status-warning` left border (2px)
- **Error**: `✕` red dot, `--status-error` left border (2px)
- **Hover**: `--bg-surface-hover`, show quick action buttons
- **Selected**: `--border-focus` border (accent green)

### Card Layout

```
┌──────────────────────────────────┐
│ ● repo-name                 ↑2  │  status dot + name + ahead count
│   branch-name               ↓0  │  branch + behind count
│   3 files modified              │  status text (or "clean")
│   CI: ✓ all passing             │  CI status
│   last: 2m ago                  │  last activity
│   [commit] [push] [graph]       │  quick actions (on hover)
└──────────────────────────────────┘
```

---

## 7. Chat View (Primary Interaction)

```
┌─────────┬───────────────────────────────────────────┬──────────────┐
│ REPOS   │  valkka (main) ● clean  ↑2               │ AI CONTEXT   │
│         │  [Chat]  [Graph]  [Diff]  [PR]            │              │
│ > valkka │─────────────────────────────────────────────│ Model:       │
│   false │                                            │ Claude 4     │
│   kerto │                                            │              │
│   sykli │                                            │ Context:     │
│         │  you                              14:22    │ ████░░ 62k   │
│         │  what changed today?                       │              │
│         │                                            │ Files:       │
│         │  valkka                             14:22   │ worker.ex    │
│         │  3 files modified in valkka today:          │ stream.ex    │
│         │                                            │ mix.exs      │
│         │   M lib/repo/worker.ex                     │              │
│         │     Added timeout handling (+15, -3)       │ Recent:      │
│         │     type: function_modified                │ 14:22 commit │
│         │                                            │ 14:20 stage  │
│         │   A lib/ai/stream.ex                       │ 13:05 commit │
│         │     New file: token streaming (42 lines)   │              │
│         │     type: module_added                     │              │
│         │                                            │              │
│         │   M test/repo_test.exs                     │              │
│         │     2 new test cases (+28, -0)             │              │
│         │                                            │              │
│         │  Suggested commit message:                 │              │
│         │  "feat: add git op timeouts and AI         │              │
│         │   token streaming"                         │              │
│         │                                            │              │
│         │  [Commit] [Show diff] [Edit message]       │              │
│         │                                            │              │
│         ├────────────────────────────────────────────┤              │
│         │  > type a command or ask a question...     │              │
└─────────┴────────────────────────────────────────────┴──────────────┘
```

### Message Types

**User message:**
```
┌──────────────────────────────────────────────────── you  14:22 ─┐
│ what changed today?                                              │
└──────────────────────────────────────────────────────────────────┘
```
Right-aligned timestamp, `--bg-surface` background, `--border-subtle` border.

**Valkka message:**
```
┌─ valkka  14:22 ──────────────────────────────────────────────────┐
│ 3 files modified in valkka today:                                 │
│                                                                  │
│  M lib/repo/worker.ex                                            │
│    Added timeout handling (+15, -3)                               │
│                                                                  │
│ [Commit] [Show diff] [Edit message]                              │
└──────────────────────────────────────────────────────────────────┘
```
Left-aligned, no background (just text), `--accent-ghost` left border (2px).

**Confirmation card:**
```
┌─── CONFIRM ─────────────────────────────────────────────────────┐
│                                                                  │
│  Force push to origin/main?                                      │
│                                                                  │
│  This will overwrite remote history. This cannot be undone.      │
│                                                                  │
│  Command: git push --force origin main                           │
│                                                                  │
│  [Cancel]  [Force push]                                          │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```
`--status-warning` left border. Destructive button in `--status-error`.

**Error message:**
```
┌─── ERROR ────────────────────────────────────────────────────────┐
│                                                                  │
│  Failed to push to origin/main:                                  │
│  remote: Permission denied (publickey)                           │
│                                                                  │
│  Suggestion: Check your SSH key.                                 │
│  Run: ssh-add ~/.ssh/id_ed25519                                  │
│                                                                  │
│  [Copy error] [Try again] [Ask AI for help]                      │
└──────────────────────────────────────────────────────────────────┘
```
`--status-error` left border.

### Command Input

```
┌──────────────────────────────────────────────────────────────────┐
│  > type a command or ask a question...              Cmd+Enter ⏎  │
└──────────────────────────────────────────────────────────────────┘
```

- `--bg-input` background
- Placeholder text in `--text-muted`
- On focus: `--border-focus` (accent green)
- `Cmd+Enter` to submit, `Shift+Enter` for newline
- Up arrow: cycle command history

### Streaming Indicator

```
  valkka
  Analyzing diff (3 files, 142 lines)...
  ▍
```

Blinking cursor (▍) at 530ms interval. Status text in `--text-secondary`.

---

## 8. Commit Graph View

```
┌─────────┬───────────────────────────────────────────┬──────────────┐
│ REPOS   │  valkka (main) ● clean                     │ COMMIT       │
│         │  [Chat]  [Graph]  [Diff]  [PR]            │              │
│ > valkka │─────────────────────────────────────────────│ a7f2c01      │
│         │  branch filter: [all ▾]  zoom: [+] [-] [0]│              │
│         │─────────────────────────────────────────────│ feat: add    │
│         │                                            │ timeout      │
│         │  ● ─── a7f2c01 feat: add timeout    2m    │ handling     │
│         │  │                                  yair   │              │
│         │  ● ─── b3e8d44 fix: stream error    1h    │ Author:      │
│         │  │                                  yair   │ yair         │
│         │  │ ● ─ c4f9e22 feat: graph layout   2h    │ 2 min ago    │
│         │  │ │                                yair   │              │
│         │  │ ● ─ d5a0f33 feat: webgl render   3h    │ Files:       │
│         │  │/                                 yair   │ M worker.ex  │
│         │  ●──── e6b1g44 merge feat/graph     4h    │ M stream.ex  │
│         │  │                                  yair   │ M repo_test  │
│         │  ● ─── f7c2h55 initial commit       1d    │              │
│         │  │                                  yair   │ +43, -3      │
│         │                                            │              │
│         │  showing 7 of 42 commits                   │ [Show diff]  │
│         │                                            │ [Cherry-pick]│
│         ├────────────────────────────────────────────┤ [Revert]     │
│         │  > show graph for last week                │              │
└─────────┴────────────────────────────────────────────┴──────────────┘
```

### Graph Rendering

- **Canvas/WebGL** via JS hook — not DOM nodes
- **Branch lanes**: vertical colored lines, one per active branch
- **Commit nodes**: filled circles (6px radius) on their branch lane
- **Merge nodes**: diamond shape (rotated square)
- **Edges**: smooth bezier curves connecting parent to child
- **Branch labels**: floating tags next to the relevant commit node

### Interactions

- **Hover commit**: highlight full branch, dim others to 30% opacity
- **Click commit**: select it, show details in context panel
- **Double-click**: expand inline detail below the commit
- **Scroll**: vertical scroll through history (virtualized, only render viewport + buffer)
- **Zoom**: `+`/`-` keys or scroll wheel with Ctrl held
- **Pan**: click and drag (when zoomed)
- **Filter**: branch dropdown, author filter, date range

### Graph Toolbar

```
┌──────────────────────────────────────────────────────────────────┐
│  branch: [all ▾]  author: [all ▾]  │  [+] [-] [0]  │  7 of 42  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 9. Diff View

```
┌─────────┬───────────────────────────────────────────┬──────────────┐
│ REPOS   │  valkka (main) ● clean                     │ FILE INFO    │
│         │  [Chat]  [Graph]  [Diff]  [PR]            │              │
│ > valkka │─────────────────────────────────────────────│ worker.ex    │
│         │  Comparing: HEAD~1 ↔ HEAD  [unified|split]│              │
│         │─────────────────────────────────────────────│ Last changed │
│ FILES   │                                            │ 2 min ago    │
│         │  lib/repo/worker.ex                        │ by yair      │
│ ▼ lib/  │  ┌─ function_modified: handle_call ──────┐│              │
│   M wor │  │                                        ││ History:     │
│   A str │  │  28   def handle_call(:exec, from, s)  ││ 12 commits   │
│ ▼ test/ │  │  29     timeout = opts[:timeout]        ││ 3 authors    │
│   M rep │  │+ 30     Logger.info("executing...")     ││              │
│         │  │+ 31     timer = Process.send_after(     ││ Kerto:       │
│ +43 -3  │  │+ 32       self(), :timeout, timeout)    ││ ⚠ breaks     │
│ 3 files │  │  33     task = Task.async(fn ->         ││   repo_test  │
│         │  │  34       Native.diff(h, from, to)      ││   (w: 0.78)  │
│         │  │  35     end)                             ││              │
│         │  │                                         ││              │
│         │  └─────────────────────────────────────────┘│              │
│         │                                             │              │
│         │  lib/ai/stream.ex (new file)                │              │
│         │  ┌─ module_added: Valkka.AI.Stream ────────┐│              │
│         │  │                                        ││              │
│         │  │+ 1  defmodule Valkka.AI.Stream do        ││              │
│         │  │+ 2    use GenServer                     ││              │
│         │  │+ 3    ...                               ││              │
│         │  │                                        ││              │
│         │  └─────────────────────────────────────────┘│              │
│         ├────────────────────────────────────────────┤              │
│         │  > explain this diff                       │              │
└─────────┴────────────────────────────────────────────┴──────────────┘
```

### Semantic Annotations

Each diff hunk gets a header badge showing the semantic change type:

```
┌─ function_modified: handle_call ──────────────────────────────────┐
┌─ function_added: validate_input ──────────────────────────────────┐
┌─ type_modified: RepoStatus ───────────────────────────────────────┐
┌─ import_changed ──────────────────────────────────────────────────┐
┌─ module_added: Valkka.AI.Stream ───────────────────────────────────┐
```

Badge color matches the change type:
- Added: `--status-success` (green)
- Modified: `--status-info` (blue)
- Removed: `--status-error` (red)

### File Tree (Left)

```
▼ lib/
  M worker.ex        +15 -3
  A stream.ex        +42
▼ test/
  M repo_test.exs    +28
─────────────────────
+43 -3  3 files
```

- `M` = modified (--status-info)
- `A` = added (--status-success)
- `D` = deleted (--status-error)
- `R` = renamed (--status-warning)
- Change counts right-aligned

### Diff Shortcuts

```
n / p        Next / previous hunk
f / F        Next / previous file
u            Toggle unified / side-by-side
c            Collapse current file
e            Expand all
[ / ]        Previous / next file in tree
```

---

## 10. PR Review View

```
┌─────────┬───────────────────────────────────────────┬──────────────┐
│ REPOS   │  false-protocol (feat/v2)                  │ REVIEW       │
│         │  [Chat]  [Graph]  [Diff]  [PR #42]        │ CHECKLIST    │
│   valkka │─────────────────────────────────────────────│              │
│ > false │  PR #42: Add occurrence v2 format          │ ☐ Code       │
│   kerto │  by yair → main  │  CI: ✓  │  +120, -30   │ ☐ Tests      │
│   sykli │                                            │ ☑ CI         │
│         │─── AI REVIEW ─────────────────────────────│ ☐ Security   │
│         │                                            │              │
│         │  Risk: LOW                                 │ Comments:    │
│         │                                            │ 2 unresolved │
│         │  Summary: Adds v2 occurrence format with   │              │
│         │  backwards-compatible parsing. Clean       │              │
│         │  separation between v1 and v2 types.       │              │
│         │                                            │              │
│         │  Suggestions:                              │              │
│         │  1. Add migration test for v1→v2           │              │
│         │  2. Consider adding version field to       │              │
│         │     the occurrence header                  │              │
│         │                                            │              │
│         │─── FILES (5) ─────────────────────────────│              │
│         │                                            │              │
│         │  ▼ lib/occurrence/v2.ex          +80       │              │
│         │    (expanded diff here)                    │              │
│         │                                            │              │
│         │  ▶ lib/occurrence/parser.ex      +20 -15   │              │
│         │  ▶ lib/occurrence/types.ex       +10 -5    │              │
│         │  ▶ test/occurrence_test.exs      +30       │              │
│         │  ▶ CHANGELOG.md                  +5        │              │
│         │                                            │              │
│         │  [Approve] [Request changes] [Comment]     │              │
│         ├────────────────────────────────────────────┤              │
│         │  > any security concerns with this PR?     │              │
└─────────┴────────────────────────────────────────────┴──────────────┘
```

### Risk Badge

```
  LOW      →  --status-success background, --text-inverse
  MEDIUM   →  --status-warning background, --text-inverse
  HIGH     →  --status-error background, --text-inverse
  CRITICAL →  --status-error background, pulsing border
```

---

## 11. Conflict Resolution View

```
┌──────────────────────────────────────────────────────────────────────┐
│  CONFLICT: lib/repo/worker.ex  (1 of 3 conflicts)      [n]ext [p]rev│
├──────────────────┬──────────────────┬────────────────────────────────┤
│ OURS (main)      │ RESULT           │ THEIRS (feat/timeout)          │
│                  │                  │                                │
│  30 def handle(  │  30 def handle(  │  30 def handle(               │
│  31   state) do  │  31   state) do  │  31   state, opts) do         │
│▓ 32   {:reply,   │▓ 32   Logger.   │▓ 32   timeout =              │
│▓ 33     result,  │▓ 33     info(   │▓ 33     opts[:timeout]       │
│▓ 34     state}   │▓ 34     "done:  │▓ 34   {:reply,               │
│  35 end          │▓ 35      #{r}") │▓ 35     result,              │
│                  │▓ 36   {:reply,  │▓ 36     state}               │
│                  │▓ 37     result, │  37 end                       │
│                  │▓ 38     state}  │                                │
│                  │  39 end         │                                │
└──────────────────┴──────────────────┴────────────────────────────────┘
│                                                                      │
│  ┌─ AI SUGGESTION ──────────────────────────────────────────────┐    │
│  │ Merged both: timeout from theirs + logging from ours.        │    │
│  │ Note: timeout is hardcoded to 5000ms — consider using the    │    │
│  │ timeout parameter from theirs instead.                       │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  [1: Accept ours]  [2: Accept theirs]  [3: Accept AI]  [Edit]       │
│                                                                      │
│  [a: Accept all AI]  [m: Mark resolved]  [n: Next conflict]         │
└──────────────────────────────────────────────────────────────────────┘
```

- **OURS**: read-only, `--status-info` tint on conflict lines
- **THEIRS**: read-only, `--status-warning` tint on conflict lines
- **RESULT**: editable, `--accent-ghost` on AI-suggested lines
- Conflict blocks highlighted with `▓` markers
- Navigate conflicts: `n`/`p` keys
- Resolve per block: `1`, `2`, `3` keys

---

## 12. Command Palette (Cmd+K)

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│          ┌────────────────────────────────────────────┐          │
│          │ > search commands, repos, branches...      │          │
│          ├────────────────────────────────────────────┤          │
│          │                                            │          │
│          │  RECENT                                    │          │
│          │   ↩  commit with AI message                │          │
│          │   ↩  show graph for valkka                  │          │
│          │                                            │          │
│          │  GIT                                       │          │
│          │   ⎇  Commit...              Cmd+Shift+C   │          │
│          │   ⎇  Push                   Cmd+Shift+P   │          │
│          │   ⎇  Pull                                  │          │
│          │   ⎇  Create branch...                      │          │
│          │   ⎇  Stash changes                         │          │
│          │                                            │          │
│          │  NAVIGATION                                │          │
│          │   →  Go to Chat              g c           │          │
│          │   →  Go to Graph             g g           │          │
│          │   →  Go to Diff              g d           │          │
│          │                                            │          │
│          │  AI                                        │          │
│          │   ◆  Review current changes                │          │
│          │   ◆  Suggest commit message                │          │
│          │   ◆  Explain this diff                     │          │
│          │                                            │          │
│          │  REPOS                                     │          │
│          │   ●  valkka                    1             │          │
│          │   ●  false-protocol           2             │          │
│          │   ●  kerto                    3             │          │
│          │                                            │          │
│          └────────────────────────────────────────────┘          │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

- **Backdrop**: `--bg-root` at 60% opacity
- **Panel**: `--bg-elevated`, 480px wide, max-height 60vh
- **Fuzzy search**: matches highlighted with `--accent`
- **Navigate**: j/k or arrows, Enter to execute
- **Categories**: uppercase, `--text-muted`, `--font-size-xs`
- **Shortcuts**: right-aligned, `--text-muted`
- **Dismiss**: Escape or click backdrop

---

## 13. Keyboard Navigation

### Global

| Key | Action |
|---|---|
| `Cmd+K` | Command palette |
| `Cmd+B` | Toggle sidebar |
| `Cmd+.` | Toggle context panel |
| `Cmd+Enter` | Confirm / submit / commit |
| `Cmd+Shift+C` | Quick commit |
| `Cmd+Shift+P` | Quick push |
| `Cmd+1..9` | Switch to repo by position |
| `Escape` | Close modal / back / deselect |
| `?` | Show shortcut overlay |

### Vim-Style

| Key | Action |
|---|---|
| `j / k` | Move down / up in any list |
| `h / l` | Collapse / expand in trees |
| `Enter` | Select / activate |
| `/` | Start search in current view |
| `n / N` | Next / previous search result |

### G-Chords (View Navigation)

| Chord | Action |
|---|---|
| `g g` | Go to Graph |
| `g d` | Go to Diff |
| `g c` | Go to Chat |
| `g p` | Go to PR Review |
| `g s` | Go to Dashboard (status) |

Status indicator when `g` is pressed:
```
  g → waiting for second key...  [1s timeout]
```

### View-Specific

**Chat:** Up/Down for history, Tab for autocomplete, Ctrl+C cancel stream
**Diff:** n/p hunks, f/F files, u toggle unified/split
**Graph:** +/- zoom, 0 reset, Home to HEAD, b toggle branch labels
**Conflict:** n/p blocks, 1/2/3 accept ours/theirs/AI, a accept all AI, m mark resolved

---

## 14. Animations

All respect `prefers-reduced-motion`. When reduced motion is set, all transitions are instant.

| Element | Animation | Duration |
|---|---|---|
| Panel collapse/expand | Width slide | 150ms ease-out |
| Panel resize | Direct tracking | No animation |
| Chat message (user) | Instant | 0ms |
| Chat message (valkka) | Slide up + fade in | 200ms ease-out |
| Action buttons | Fade in after message | 100ms |
| Graph node hover | Scale 1.0 → 1.3 | 100ms ease-out |
| Branch highlight | Others dim to 30% | 200ms ease-out |
| Command palette open | Fade + scale 0.97→1.0 | 150ms ease-out |
| Command palette close | Reverse | 100ms |
| Status dot color change | Color transition | 300ms ease |
| Toast notification | Slide in from right | 200ms ease-out |
| Skeleton loading | Pulse opacity 0.3↔0.7 | 1500ms ease-in-out |

---

## 15. Notifications (Toasts)

Bottom-right, stacked upward, max 3 visible.

```
                                    ┌──────────────────────────────┐
                                    │ ✓ Committed a7f2c01         │
                                    │   "Add timeout handling"     │
                                    │                    5s  [undo]│
                                    └──────────────────────────────┘
```

| Type | Left border color |
|---|---|
| Success | `--status-success` |
| Error | `--status-error` |
| Warning | `--status-warning` |
| Info | `--status-info` |

Auto-dismiss 5s. Hover to pause. Click to dismiss. `[undo]` where applicable.

---

## 16. Iconography

No icon library. Text characters from the monospace font:

```
STATUS:     ●  clean    ◐  dirty    ○  empty    ✕  failed    ✓  passed
ARROWS:     ↑  ahead    ↓  behind   →  go to    ↩  recent
GIT:        ⎇  branch/operation
AI:         ◆  AI action/suggestion
FILE:       M  modified   A  added   D  deleted   R  renamed
NAV:        ▼  expanded   ▶  collapsed   >  current/active
MISC:       ▍  cursor (streaming)   │  separator   ─  rule
```

---

## 17. Component Hierarchy

```
AppLayout
├── StatusBar
├── Sidebar
│   ├── RepoList
│   │   └── RepoListItem
│   ├── BranchList
│   │   └── BranchListItem
│   └── QuickStatus
├── MainPanel
│   ├── TabBar
│   ├── ChatView
│   │   ├── ContextBar
│   │   ├── MessageStream
│   │   │   ├── UserMessage
│   │   │   ├── ValkkaMessage
│   │   │   │   ├── TextBlock
│   │   │   │   ├── CodeBlock
│   │   │   │   ├── DiffBlock (inline)
│   │   │   │   ├── ActionButtons
│   │   │   │   └── ConfirmationCard
│   │   │   └── StreamingIndicator
│   │   └── CommandInput
│   ├── GraphView
│   │   ├── GraphToolbar
│   │   ├── GraphCanvas (JS hook)
│   │   └── CommitDetail
│   ├── DiffView
│   │   ├── DiffToolbar
│   │   ├── FileTree
│   │   ├── DiffContent (JS hook)
│   │   └── SemanticBadge
│   ├── PRView
│   │   ├── PRSummary
│   │   ├── AIReview
│   │   ├── PRFileList
│   │   └── PRActions
│   └── ConflictView
│       ├── ThreeWayDiff
│       ├── AISuggestion
│       └── ConflictActions
├── ContextPanel
│   ├── AIContext
│   ├── CommitDetailPanel
│   ├── FileInfoPanel
│   └── ReviewChecklist
├── CommandPalette (overlay)
│   ├── PaletteInput
│   └── PaletteResults
│       └── PaletteItem
├── ToastContainer
│   └── Toast
└── FooterBar
```

---

## 18. Accessibility

- **Keyboard**: every feature accessible without mouse
- **Focus rings**: 2px solid `--accent`, 2px offset on all focusable elements
- **ARIA labels**: on icon-only indicators (status dots, file status letters)
- **Live regions**: toast notifications, streaming AI responses, status changes
- **Contrast**: all text meets WCAG AA (4.5:1 minimum)
  - `--text-primary` on `--bg-root`: 15.2:1
  - `--text-secondary` on `--bg-root`: 7.8:1
  - `--accent` on `--bg-root`: 13.1:1
- **Semantic HTML**: headings, lists, buttons, landmarks
- **Reduced motion**: all animations disabled when `prefers-reduced-motion: reduce`

---

## 19. Design Checklist

For every new component, verify:

```
[ ] Keyboard-accessible without mouse?
[ ] Works with j/k navigation?
[ ] Reachable from command palette?
[ ] Uses only defined color tokens?
[ ] Uses monospace typography?
[ ] Corners square (max 2px radius)?
[ ] Respects prefers-reduced-motion?
[ ] Information-dense but not cluttered?
[ ] Integrates with chat (natural language trigger)?
[ ] Shows git command before executing?
[ ] Confirms destructive operations?
```
