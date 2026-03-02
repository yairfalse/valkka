# Känni: User Stories & MVP Scope

> What the user does. Not what the system does.

---

## 1. Target User

**The Agent Developer.** Works primarily with AI coding agents (Claude Code, Cursor, Copilot). Doesn't live in an IDE. Lives in the terminal. Needs a git command center that understands their workflow:

- Multiple repos open simultaneously
- Agents making changes they need to review
- Fast context switching between projects
- Natural language over memorized git flags
- CI awareness without opening a browser

---

## 2. User Stories (Prioritized)

### P0: Must Ship in MVP

#### US-01: First Launch
> As a developer, I want to point Känni at a directory and immediately see all my repos' status, so I can orient myself without running git commands.

**Flow:**
```
1. User runs: känni ~/projects
2. Känni scans for .git directories (1 level deep by default)
3. Dashboard shows all found repos with:
   - Name, current branch, clean/dirty status
   - Commits ahead/behind upstream
   - Last commit message and time
4. User can click a repo to focus on it
```

**Acceptance criteria:**
- Scans and displays within 2 seconds for 10 repos
- Shows real-time updates as files change
- Remembers workspace on next launch

#### US-02: Natural Language Git
> As a developer, I want to type what I want in plain English and have Känni execute the right git commands, so I don't have to remember flags.

**Flow:**
```
1. User types: "show me what changed today"
2. Känni parses intent → {:query, :changes_since, %{since: "today"}}
3. Runs NIF: log(handle, %{since: today_midnight})
4. Displays: list of commits with semantic summaries
```

**Common intents for MVP:**
| User says | Intent | Git operation |
|---|---|---|
| "what changed today" | query:changes_since | git log --since |
| "commit this with a good message" | ai_op:generate_commit_msg | git diff → AI → git commit |
| "show the diff" | query:diff | git diff |
| "switch to main" | git_op:checkout | git checkout main |
| "squash last 3 commits" | git_op:squash | git rebase -i |
| "what branch am I on" | query:status | git status |
| "push this" | git_op:push | git push |
| "create a branch called feat/auth" | git_op:create_branch | git checkout -b |
| "merge feat/auth into main" | git_op:merge | git merge |
| "who changed this file" | query:blame | git blame |
| "undo last commit" | git_op:reset | git reset HEAD~1 |

**Acceptance criteria:**
- 80% of common intents parsed without AI (regex/patterns)
- Ambiguous intents fall through to LLM
- Destructive operations always require confirmation
- Shows what git command will be executed before running

#### US-03: AI Commit Messages
> As a developer, I want Känni to read my diff and suggest a commit message, so I can commit faster with better messages.

**Flow:**
```
1. User has uncommitted changes
2. Types: "commit" or clicks Commit button
3. Känni runs semantic_diff on staged changes
4. AI generates commit message from structured diff
5. User sees message, can edit or accept
6. Känni commits
```

**Acceptance criteria:**
- Semantic diff (not raw diff) fed to AI for better messages
- Message follows conventional commits format (configurable)
- User can edit before confirming
- Shows diff summary alongside suggested message

#### US-04: Commit Graph
> As a developer, I want to see a beautiful visual commit graph that I can zoom, pan, and interact with, so I can understand branch topology at a glance.

**Flow:**
```
1. User opens repo view or types "show graph"
2. Rust NIF computes graph layout (positions, columns, edges)
3. WebGL/Canvas renders interactive graph
4. User can:
   - Zoom in/out (scroll)
   - Pan (drag)
   - Click commit → show details
   - Hover branch → highlight all its commits
   - Filter by author, date range, path
```

**Acceptance criteria:**
- 1000 commits render in < 100ms
- Smooth 60fps pan/zoom
- Branch colors are consistent and distinguishable
- Merge commits clearly show merge topology

#### US-05: Real-Time File Watching
> As a developer, I want Känni to update instantly when files change on disk, so I always see current state without refreshing.

**Flow:**
```
1. Agent (Claude Code) modifies files in repo
2. FSEvents/inotify detects changes within 100ms
3. Repo worker refreshes status via NIF
4. Dashboard updates: "3 files modified"
5. Diff view updates if open
```

**Acceptance criteria:**
- Changes reflected in UI within 200ms of file write
- No polling — event-driven only
- Works across all monitored repos simultaneously

#### US-06: Multi-Repo Workspace
> As a developer, I want to see all my repos in one view and switch between them instantly, so I don't need multiple terminal tabs.

**Flow:**
```
1. Dashboard shows all repos as cards
2. Each card: name, branch, status summary, last activity
3. Click card → repo detail view
4. Can run cross-repo queries: "which repos have uncommitted changes?"
```

**Acceptance criteria:**
- Support 20+ repos without performance degradation
- Each repo is isolated (one crash doesn't affect others)
- Cross-repo queries work in natural language

---

### P1: Ship Soon After MVP

#### US-07: PR Review with AI
> As a developer, I want Känni to review a PR and give me a structured assessment with risks and suggestions, so I can review faster.

**Flow:**
```
1. User: "review PR #42"
2. Känni fetches PR diff (GitHub API)
3. Runs semantic_diff → structured changes
4. AI analyzes: summary, file-by-file, risks, suggestions
5. Streams response to chat
6. User can approve/request changes directly from Känni
```

#### US-08: Conflict Resolution with AI
> As a developer, I want Känni to show me merge conflicts with AI-suggested resolutions, so I can resolve conflicts without opening an editor.

#### US-09: Branch Health Dashboard
> As a developer, I want to see which branches are stale, which are ahead/behind, and which have conflicts, so I can manage branches proactively.

#### US-10: Kerto Integration
> As a developer, I want Känni to feed git operations into Kerto's knowledge graph, so my project context accumulates over time.

#### US-11: Sykli Integration
> As a developer, I want to see CI status from Sykli directly in Känni, so I know if my changes are passing without switching tools.

---

### P2: Future

#### US-12: Session Memory
> As a developer, I want Känni to remember what I did across sessions, so I can ask "what was that command I ran yesterday?"

#### US-13: Team Collaboration
> As a team, we want to share workspace state via mesh networking (BEAM distribution), so we can collaborate without a central server.

#### US-14: MCP Server
> As an AI agent, I want to access Känni's git operations via MCP, so I can perform git operations without CLI.

#### US-15: Custom Workflows
> As a developer, I want to define reusable workflows ("prepare release" = tag + changelog + push), so I can automate repetitive sequences.

---

## 3. MVP Scope

### In (v0.1)

| Feature | User Stories | Effort |
|---|---|---|
| Workspace scanning & dashboard | US-01, US-06 | 1 week |
| Rust NIF with git2-rs (core ops) | US-02, US-03, US-04 | 2 weeks |
| Chat interface with intent parsing | US-02 | 1 week |
| AI commit messages | US-03 | 3 days |
| Commit graph (WebGL) | US-04 | 1 week |
| Real-time file watching | US-05 | 3 days |
| Basic git operations (commit, branch, merge, push, pull) | US-02 | 1 week |

**Total MVP: ~6 weeks**

### Out (post-MVP)

- PR review (US-07) — needs GitHub API integration
- Conflict resolution (US-08) — needs semantic merge engine
- Kerto integration (US-10) — needs FALSE Protocol support
- Sykli integration (US-11) — needs Sykli occurrence parsing
- Team features (US-13) — needs BEAM distribution
- MCP server (US-14) — needs MCP protocol implementation

### MVP Success Criteria

1. **Daily driver test:** Can you use Känni for all git operations for 1 week without touching `git` CLI?
2. **Speed test:** Every operation feels instant (< 200ms for git ops, < 1s for AI start)
3. **Stability test:** Leave Känni running for 24 hours watching 5 repos. Zero crashes.

---

## 4. First 5 Minutes (Onboarding Flow)

```
$ känni

  ╦╔═╔═╗╔╗╔╔╗╔╦
  ╠╩╗╠═╣║║║║║║║
  ╩ ╩╩ ╩╝╚╝╝╚╝╩

  Welcome to Känni — your AI-native git command center.

  Scanning ~/projects for repositories...

  Found 4 repos:
    kanni          main     clean     2 min ago
    false-protocol feat/v2  3 dirty   15 min ago
    kerto          main     clean     1 hour ago
    sykli          main     clean     3 hours ago

  > type a command or ask a question...

  Tip: try "what changed today?" or "show graph for kerto"
```

---

## 5. Patterns Borrowed from Kerto & Sykli

### From Kerto
- **Occurrence-driven events**: Every git operation becomes an Occurrence (feeds into knowledge graph)
- **Content-addressed identity**: Same commit SHA = same entity everywhere
- **EWMA for freshness**: Branch activity weighted by recency
- **MCP as primary interface**: Not a CLI with MCP bolted on — MCP-first
- **Three-tier persistence**: Hot (ETS) / Warm (ETF) / Cold (JSON)
- **Pure domain layer**: Git domain logic is testable without real repos
- **Strict dependency layers**: Domain → Application → Infrastructure

### From Sykli
- **Structured context generation**: `.kanni/context.json` for AI agents
- **Rich error formatting**: Git errors become structured, not raw stderr
- **Same code local/remote**: BEAM distribution for future team features
- **AI-native metadata**: Semantic understanding of what changed
- **Burrito for distribution**: Single binary for all platforms
