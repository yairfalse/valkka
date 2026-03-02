# Känni Domain Model

> The domain model defines what Känni *is* — the language, the concepts, the rules.
> Code that doesn't speak this language is wrong.

---

## 1. Ubiquitous Language

These terms mean exactly one thing across the entire codebase. If you're writing code and reach for a different word, stop — use these.

| Term | Definition |
|---|---|
| **Workspace** | A collection of monitored repositories. The user's project scope. One user has one active workspace. |
| **Repository** | A monitored git repository. Känni watches it, knows its state, operates on it. Not just a path — a living, observed entity. |
| **Conversation** | A sequence of exchanges between the user and Känni within a workspace. The primary interaction model. Persists across sessions. |
| **Utterance** | A single user input in a conversation. Could be natural language, a command, or a question. |
| **Intent** | The parsed meaning of an utterance. What the user wants to happen. Classified into git operations, queries, or AI-assisted operations. |
| **Operation** | A git action that mutates repository state: commit, merge, rebase, cherry-pick, etc. Always requires confirmation before execution. |
| **Query** | A read-only request for information: "what changed?", "who wrote this?", "show the graph." Never mutates state. |
| **SemanticDiff** | A language-aware diff that understands code structure — functions added, modified, renamed — not just lines changed. Känni's technical moat. |
| **Graph** | The visual representation of commit history — branches, merges, forks. Computed as a layout with positions, not just raw data. |
| **Review** | An AI-powered analysis of changes (PR, branch, or uncommitted work). Produces a structured assessment with summary, risks, and suggestions. |
| **Suggestion** | An actionable proposal from Känni — a commit message, a conflict resolution, a review comment. User accepts, modifies, or rejects. |
| **Conflict** | A merge conflict with full context: both sides, common ancestor, and AI-proposed resolution. |
| **RepoStatus** | The current state snapshot of a repository: head, branch, clean/dirty, ahead/behind, active operations. |
| **Watcher** | The file system observer for a repository. Detects changes and triggers state refresh. |

---

## 2. Bounded Contexts

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ┌──────────────────┐    ┌──────────────────┐               │
│  │   Conversation   │───→│   Git Engine      │              │
│  │   Context        │    │   Context          │             │
│  │                  │    │                    │              │
│  │  Utterance       │    │  Repository        │             │
│  │  Intent          │    │  Commit            │             │
│  │  Conversation    │    │  Branch            │             │
│  │  Suggestion      │    │  Diff / SDiff      │             │
│  │  Response        │    │  Graph             │             │
│  └────────┬─────────┘    │  Operation         │             │
│           │              │  Conflict          │             │
│           │              │  RepoStatus        │             │
│           ▼              └────────┬───────────┘             │
│  ┌──────────────────┐             │                         │
│  │   AI Context      │◄───────────┘                         │
│  │                   │                                      │
│  │  IntentParser     │    ┌──────────────────┐              │
│  │  ContextBuilder   │    │  Workspace       │              │
│  │  StreamSession    │    │  Context         │              │
│  │  Review           │    │                  │              │
│  │  Provider         │    │  Workspace       │              │
│  └───────────────────┘    │  RepoRegistry    │              │
│                           │  Config          │              │
│                           └──────────────────┘              │
│                                                             │
│  ┌──────────────────┐    ┌──────────────────┐               │
│  │  Presentation    │    │  Observation      │              │
│  │  Context         │    │  Context          │              │
│  │                  │    │                   │              │
│  │  ChatView        │    │  Watcher          │              │
│  │  GraphView       │    │  ChangeEvent      │              │
│  │  DiffView        │    │  RefreshTrigger   │              │
│  │  StatusView      │    └──────────────────┘               │
│  └──────────────────┘                                       │
└─────────────────────────────────────────────────────────────┘
```

### Context Relationships

| Upstream | Downstream | Relationship | Integration |
|---|---|---|---|
| Git Engine | Conversation | Customer/Supplier | Conversation requests operations; Git Engine executes |
| Git Engine | AI | Customer/Supplier | AI reads repo state to build context |
| AI | Conversation | Customer/Supplier | Conversation sends utterances; AI returns intents and reviews |
| Observation | Git Engine | Published Language | Watcher publishes change events; Git Engine refreshes state |
| Git Engine | Presentation | Open Host | Presentation subscribes to state via PubSub |
| AI | Presentation | Open Host | Presentation subscribes to AI streams via PubSub |
| Workspace | Git Engine | Shared Kernel | Both share the concept of "which repos are active" |

---

## 3. Aggregates

### 3.1 Repository (Git Engine Context)

**The central aggregate.** All git state flows through this.

```
Repository (Aggregate Root)
├── identity: repo_id (generated, stable across sessions)
├── path: filesystem path
├── handle: ResourceArc (opaque Rust reference)
│
├── RepoStatus (Value Object)
│   ├── head: OID
│   ├── branch: branch name | :detached
│   ├── state: :clean | :dirty | :merging | :rebasing | :cherry_picking
│   ├── staged: [FileDelta]
│   ├── unstaged: [FileDelta]
│   ├── untracked: [path]
│   ├── ahead: integer (commits ahead of upstream)
│   └── behind: integer (commits behind upstream)
│
├── branches(): [Branch]
├── log(opts): [Commit]
├── graph(opts): GraphLayout
├── diff(from, to): Diff
├── semantic_diff(from, to): SemanticDiff
│
└── Operations (mutating — require confirmation)
    ├── commit(message, opts) → Commit
    ├── stage(paths) → RepoStatus
    ├── unstage(paths) → RepoStatus
    ├── checkout(ref) → RepoStatus
    ├── merge(source) → MergeResult
    ├── rebase(opts) → RebaseResult
    ├── squash(count, message) → Commit
    ├── cherry_pick(oid) → CherryPickResult
    ├── stash(message) → :ok
    └── create_branch(name, target) → Branch
```

**Invariants:**
- A Repository always has a valid handle (or is in :error state)
- Operations that mutate state always broadcast a state change event
- Destructive operations (force push, reset --hard) require explicit double-confirmation
- Only one mutating operation runs at a time per repository (serialized via GenServer)

### 3.2 Conversation (Conversation Context)

```
Conversation (Aggregate Root)
├── identity: conversation_id
├── workspace_id: reference to workspace
├── started_at: timestamp
│
├── exchanges: [Exchange] (ordered)
│   └── Exchange (Entity)
│       ├── utterance: Utterance (Value Object)
│       │   ├── raw_text: string
│       │   ├── timestamp: datetime
│       │   └── source: :user | :agent
│       ├── intent: Intent | nil (Value Object)
│       │   ├── type: :git_op | :query | :ai_op
│       │   ├── action: atom
│       │   └── params: map
│       ├── response: Response (Value Object)
│       │   ├── content: string (markdown)
│       │   ├── suggestions: [Suggestion]
│       │   ├── artifacts: [Artifact] (graphs, diffs, etc.)
│       │   └── status: :streaming | :complete | :error
│       └── confirmation: Confirmation | nil
│           ├── operation: Intent
│           ├── status: :pending | :approved | :rejected
│           └── decided_at: datetime | nil
│
└── active_repo: repo_id | nil (conversation focus)
```

**Invariants:**
- Exchanges are append-only. You never edit conversation history.
- A mutating operation cannot execute without a Confirmation in :approved state.
- If active_repo is nil, ambiguous operations must ask which repo.

### 3.3 Review (AI Context)

```
Review (Aggregate Root)
├── identity: review_id
├── repo_id: reference
├── target: :pr | :branch | :uncommitted
├── target_ref: PR number | branch name | nil
│
├── status: :building_context | :streaming | :complete | :error
│
├── summary: string
├── risk_level: :low | :medium | :high | :critical
│
├── file_analyses: [FileAnalysis] (Entity)
│   ├── path: string
│   ├── change_type: :added | :modified | :deleted | :renamed
│   ├── semantic_changes: [SemanticChange]
│   ├── assessment: string
│   ├── risks: [Risk]
│   └── suggestions: [Suggestion]
│
├── overall_suggestions: [Suggestion]
└── conversation_id: reference (the review lives in a conversation)
```

**Invariants:**
- A review is immutable once status is :complete.
- Risk level is computed from file analyses, not set manually.
- Suggestions reference specific file paths and line ranges.

### 3.4 Workspace (Workspace Context)

```
Workspace (Aggregate Root)
├── identity: workspace_id
├── name: string
├── root_path: filesystem path
│
├── repositories: [RepoRegistration] (Entity)
│   ├── repo_id: identity
│   ├── path: filesystem path
│   ├── alias: string (short name for conversation)
│   ├── auto_watch: boolean
│   └── added_at: datetime
│
├── config: WorkspaceConfig (Value Object)
│   ├── ai_provider: :anthropic | :openai | :local
│   ├── ai_model: string
│   ├── auto_suggest_commits: boolean
│   ├── confirm_destructive: boolean (always true by default)
│   └── theme: string
│
└── conversations: [conversation_id] (references only)
```

**Invariants:**
- No two repositories in a workspace share the same path.
- A workspace always has at least one repository (or is being set up).
- confirm_destructive defaults to true and cannot be permanently disabled.

---

## 4. Value Objects

These have no identity. They are equal if their values are equal.

```elixir
# A point in git history
defmodule Känni.Git.OID do
  @type t :: %__MODULE__{sha: String.t()}
end

# A commit snapshot
defmodule Känni.Git.Commit do
  @type t :: %__MODULE__{
    oid: OID.t(),
    message: String.t(),
    author: Author.t(),
    committer: Author.t(),
    timestamp: DateTime.t(),
    parents: [OID.t()]
  }
end

# A branch pointer
defmodule Känni.Git.Branch do
  @type t :: %__MODULE__{
    name: String.t(),
    target: OID.t(),
    upstream: String.t() | nil,
    is_head: boolean()
  }
end

# A file change in a diff
defmodule Känni.Git.FileDelta do
  @type t :: %__MODULE__{
    path: String.t(),
    old_path: String.t() | nil,
    status: :added | :modified | :deleted | :renamed | :copied,
    insertions: non_neg_integer(),
    deletions: non_neg_integer()
  }
end

# A semantic change (the differentiator)
defmodule Känni.Git.SemanticChange do
  @type t :: %__MODULE__{
    type: :function_added | :function_modified | :function_removed |
          :type_added | :type_modified | :type_removed |
          :import_changed | :file_renamed | :signature_changed,
    name: String.t(),
    file: String.t(),
    summary: String.t(),
    lines_added: non_neg_integer(),
    lines_removed: non_neg_integer()
  }
end

# A node in the commit graph layout
defmodule Känni.Git.GraphNode do
  @type t :: %__MODULE__{
    oid: OID.t(),
    column: non_neg_integer(),
    row: non_neg_integer(),
    parents: [{OID.t(), :direct | :merge}],
    branch: String.t() | nil
  }
end

# An AI suggestion
defmodule Känni.AI.Suggestion do
  @type t :: %__MODULE__{
    type: :commit_message | :conflict_resolution | :review_comment | :operation,
    content: String.t(),
    confidence: float(),
    context: map()
  }
end
```

---

## 5. Domain Events

Events are facts. They happened. They are immutable and past-tense.

### Git Engine Events

```elixir
# Repository lifecycle
RepoOpened       %{repo_id, path, status}
RepoRefreshed    %{repo_id, old_status, new_status}
RepoCrashed      %{repo_id, reason}
RepoRecovered    %{repo_id}

# State changes
FilesChanged     %{repo_id, changes: [FileDelta]}
BranchSwitched   %{repo_id, from, to}
CommitCreated    %{repo_id, oid, message}
MergeCompleted   %{repo_id, source, target, oid}
MergeFailed      %{repo_id, source, target, conflicts: [path]}
RebaseCompleted  %{repo_id, onto, count}
ConflictDetected %{repo_id, paths: [path], context}
```

### Conversation Events

```elixir
UtteranceReceived    %{conversation_id, text, timestamp}
IntentParsed         %{conversation_id, intent}
ConfirmationRequested %{conversation_id, operation, description}
ConfirmationDecided   %{conversation_id, operation, decision: :approved | :rejected}
ResponseStreaming     %{conversation_id, chunk}
ResponseCompleted    %{conversation_id, response}
```

### AI Events

```elixir
ReviewStarted     %{review_id, repo_id, target}
ReviewStreaming    %{review_id, chunk}
ReviewCompleted   %{review_id, summary, risk_level}
IntentClassified  %{utterance, intent, confidence}
SuggestionMade    %{conversation_id, suggestion}
```

### Workspace Events

```elixir
WorkspaceCreated  %{workspace_id, name, path}
RepoAdded         %{workspace_id, repo_id, path}
RepoRemoved       %{workspace_id, repo_id}
ConfigUpdated     %{workspace_id, key, old_value, new_value}
```

---

## 6. Domain Services

These are stateless operations that don't belong to a single aggregate.

### IntentParser (crosses Conversation ↔ AI boundary)

```
parse(utterance, repo_context) → Intent

Takes raw text + current repo state.
Returns a structured intent.
Fast path: regex patterns for common commands.
Slow path: LLM classification for ambiguous input.
```

### OperationExecutor (crosses Conversation ↔ Git Engine boundary)

```
execute(repo_id, intent, confirmation) → Result

Takes a confirmed intent and runs it against the repository.
Handles the translation from intent to NIF calls.
Publishes domain events on success/failure.
```

### ContextBuilder (AI Context)

```
build(repo_id, intent) → AIContext

Assembles the right context for an AI operation:
- For commit messages: staged diff + recent commits
- For PR review: full semantic diff + file history + PR description
- For conflict resolution: both sides + common ancestor + file purpose

Manages token budget — never sends more than the model can handle.
```

### SemanticAnalyzer (Git Engine, powered by Rust)

```
analyze(diff) → SemanticDiff

Takes a raw diff and produces a structural analysis.
Uses tree-sitter to parse both sides of changed files.
Compares ASTs to identify function/type/import changes.
This is the core technical differentiator.
```

---

## 7. Context Map (Integration Patterns)

```
┌─────────────────┐         ┌──────────────────┐
│                 │  PubSub  │                  │
│  Observation    │────────→│   Git Engine      │
│  (Watcher)      │ events  │   (Repository)    │
│                 │         │                  │
└─────────────────┘         └───────┬──────────┘
                                    │
                              PubSub│state changes
                                    │
              ┌─────────────────────┼─────────────────┐
              │                     │                  │
              ▼                     ▼                  ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐
│                  │  │                  │  │              │
│  Conversation    │  │  AI Context      │  │ Presentation │
│  (Chat)          │←→│  (Brain)         │  │ (LiveView)   │
│                  │  │                  │  │              │
└──────────────────┘  └──────────────────┘  └──────────────┘
        │                                          ▲
        │              PubSub                      │
        └──────────────────────────────────────────┘
                    responses, suggestions
```

### Anti-Corruption Layer: Rust NIF Boundary

The Rust NIF is infrastructure, not domain. The domain never touches NIF types directly.

```
Domain types (Elixir structs)
    ↕ translation layer (Känni.Git.Native module)
Rust NIF returns (raw maps/tuples)
```

`Känni.Git.Native` translates NIF return values into domain value objects. The rest of the application only sees `%Commit{}`, `%Branch{}`, `%SemanticDiff{}` — never raw NIF data.

---

## 8. Key Design Decisions

### Why Conversation is an Aggregate, not just UI state

The conversation has real invariants:
- Operations require confirmation before execution
- History is append-only (audit trail)
- The active repo context affects intent parsing

If conversation were just UI state, these rules would leak into the LiveView. By making it a proper aggregate, the domain enforces them.

### Why Repository is the central Aggregate, not Workspace

The workspace is organizational. The repository is operational. All meaningful invariants (one mutation at a time, state consistency, handle lifecycle) belong to the repository. The workspace just knows which repos exist.

### Why SemanticDiff is a Value Object, not an Entity

A semantic diff has no identity. It's a pure function of two OIDs. The same inputs always produce the same output. It can be cached by `{from_oid, to_oid}` key, but it's never "updated" — only recomputed.

### Why Review is its own Aggregate

A review has its own lifecycle (building → streaming → complete), its own invariants (immutable once complete, risk computed not assigned), and can be referenced independently. It's not just a response in a conversation — it's a first-class domain concept with its own rules.
