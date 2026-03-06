# Valkka-0 — The First Usable Version

> The smallest thing that changes how you work.

---

## What Valkka-0 Is

Valkka-0 is a real-time multi-repo surface that shows you three things:

1. **What state your repos are in** — live, no `git status` needed
2. **What Kerto knows** — context visible, not hidden in a graph
3. **What just happened** — activity stream as changes flow in

And lets you act: stage, commit, push — without leaving the surface.

---

## What Valkka-0 Is NOT

- No chat interface (yet)
- No natural language git (yet)
- No AI commit messages (yet)
- No command palette (yet)
- No PR review (yet)
- No conflict resolution (yet)

These all layer on top once the foundation works. Valkka-0 is the foundation.

---

## The Three Panels

```
┌──────────────┬────────────────────────────────┬──────────────────┐
│              │                                │                  │
│  REPOS       │  FOCUS                         │  CONTEXT         │
│              │                                │                  │
│  All repos,  │  The selected repo's           │  What Kerto      │
│  live state, │  current state:                │  knows about     │
│  at a glance │  changes, diff, graph          │  what you're     │
│              │                                │  looking at      │
│              │                                │                  │
│              ├────────────────────────────────┤                  │
│              │  ACTIVITY                      │                  │
│              │  What just happened            │                  │
│              │  across all repos              │                  │
└──────────────┴────────────────────────────────┴──────────────────┘
```

### 1. Repos Panel (left)

Every monitored repo, live:

```
● valkka          main     clean      now
◐ false-protocol feat/v2  3 dirty    2m ago
● kerto          main     clean      1h ago
● sykli          main     clean      3h ago
```

- Status updates in real-time as files change
- Click/select to focus
- `Cmd+1..9` to jump by position

### 2. Focus Panel (center)

What you're looking at. Three sub-views, switchable:

**Changes** (default) — staged, unstaged, untracked files with inline diff
**Graph** — commit history visualization (WebGL, virtualized)
**Diff** — detailed diff view for selected file or commit

Actions available in changes view:
- Stage/unstage files (`s` / `u`)
- Commit (`c` — opens message input)
- Push (`p`)
- All with keyboard

### 3. Context Panel (right)

What Kerto knows about whatever you're focused on.

When focused on a repo:
```
KERTO CONTEXT: false-protocol

Patterns:
  ⚠ occurrence.go often breaks parser_test.go
    weight: 0.78 | seen 8 times | last: 3 days ago

  ★ Team decided: FALSE Protocol v2 uses ULID
    weight: 0.85 | decided 2 weeks ago

Relationships:
  occurrence.go ──breaks──→ parser_test.go
  handler.go ──depends_on──→ types.go
  types.go ──often_changes_with──→ handler.go

Recent Agent Learnings:
  "Cache in occurrence store must be bounded" (5 days ago)
  "v2 format needs backward-compatible parsing" (1 week ago)
```

When focused on a file (in diff view):
```
KERTO CONTEXT: occurrence.go

Risk: HIGH (breaks tests often)
  parser_test.go  weight: 0.78
  handler_test.go weight: 0.45

Decisions about this file:
  "ULID over UUID for occurrence IDs"

Changes with this file:
  handler.go (82% co-change rate)
  types.go (65% co-change rate)
```

### 4. Activity Stream (bottom center)

What just happened, across all repos:

```
14:22  false-protocol  M src/occurrence.go        +15 -3
14:22  false-protocol  M src/handler.go           +8 -2
14:21  kerto           committed "fix decay timer" (a7f2c01)
14:18  false-protocol  M src/types.go             +5 -0
14:15  valkka           pushed main → origin/main
```

Live. No refresh. Changes appear as agents (or you) modify files.

---

## User Stories

### US-01: Open and Orient

> I open Valkka, point it at ~/projects, and immediately see all my repos and what state they're in. No commands needed.

**Acceptance:**
- Scans for .git directories, shows all repos within 2 seconds
- Shows branch, clean/dirty, ahead/behind for each
- Updates in real-time as files change

### US-02: See What's Happening

> While agents work across my repos, I see changes flowing in live. I don't need to check each repo manually.

**Acceptance:**
- File changes appear in activity stream within 200ms
- No polling — event-driven (FSEvents/inotify)
- Activity across all repos in one stream

### US-03: See What Kerto Knows

> When I focus on a repo or file, I see what Kerto has learned about it — patterns, risks, decisions, relationships.

**Acceptance:**
- Context panel populates when repo/file is selected
- Shows patterns (with confidence weights), decisions, relationships
- Shows recent agent learnings
- Updates as Kerto graph changes

### US-04: Review Changes in Context

> I open a diff and see not just what changed, but what Kerto knows about the files involved — which are risky, which change together, what decisions were made.

**Acceptance:**
- Diff view shows Kerto warnings inline (e.g., "this file often breaks tests")
- File risk level visible at a glance
- Co-change relationships shown

### US-05: Act Fast

> I see changes, I decide to commit. I stage files, write a message, commit, push — all without leaving Valkka.

**Acceptance:**
- Stage/unstage with keyboard (`s` / `u`)
- Commit with `c`, message input, confirm with `Cmd+Enter`
- Push with `p`
- All operations confirmed before execution
- Toast notification on success/failure

### US-06: Commit Graph

> I want to see the branch topology — who merged what, where branches diverge — rendered beautifully and interactively.

**Acceptance:**
- WebGL/Canvas rendering, not DOM
- 1000 commits in < 100ms
- Smooth pan/zoom
- Click commit to see details + Kerto context

---

## Technical Scope

### What we build:

| Component | Tech | Effort |
|-----------|------|--------|
| Workspace scanning + repo discovery | Rust NIF (git2-rs) | exists |
| Real-time file watching | FSEvents + PubSub | exists (watcher handler) |
| Repo state (status, branches, ahead/behind) | Rust NIF | partially exists |
| LiveView layout (3 panels + activity) | Phoenix LiveView | new |
| Changes view (staged/unstaged/diff) | LiveView + JS hook | new |
| Commit graph | Rust NIF (layout) + JS hook (render) | partially exists |
| Kerto integration (context queries) | Kerto as dependency | new |
| Context panel (Kerto rendering) | LiveView | new |
| Activity stream | PubSub → LiveView | new |
| Git actions (stage, commit, push) | Rust NIF | new |

### What we DON'T build (yet):

- Chat interface
- Natural language intent parsing
- AI commit message generation
- AI-powered review
- Conflict resolution
- Command palette
- Sykli integration
- MCP server

### Dependencies:

- **Kerto** as a Mix dependency (embedded, same BEAM VM)
- **Rust NIF** for git operations (exists)
- **Phoenix LiveView** for real-time UI (exists)

---

## Success Criteria

1. **The awareness test:** Open Valkka alongside your agents. Can you tell what's happening across your repos without running any git commands?

2. **The context test:** When you look at a file diff, does Kerto context change how you think about it?

3. **The action test:** Can you stage, commit, and push without leaving Valkka?

4. **The speed test:** Every interaction feels instant. < 200ms for git ops, < 100ms for UI updates.

5. **The stability test:** Leave Valkka running for 24 hours watching 5 repos. Zero crashes.

---

## What Comes After Valkka-0

Once the surface works, everything else layers on:

| Feature | What it adds |
|---------|-------------|
| Chat interface | Natural language interaction with the surface |
| AI commit messages | Context-aware commit suggestions (using Kerto) |
| Agent activity protocol | Agents report what they're doing, not just what they changed |
| PR review | AI-powered review with full Kerto context |
| Conflict resolution | Three-way merge with AI suggestions |
| Sykli integration | CI status inline |
| Command palette | Fuzzy search across repos, branches, commands |

Each of these is a layer on the foundation, not a redesign.
