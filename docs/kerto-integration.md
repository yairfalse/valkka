# Känni × Kerto Integration

> Every git operation Känni performs becomes knowledge in Kerto's graph.
> Kerto makes Känni smarter over time.

---

## 1. The Integration

Känni performs git operations. Kerto remembers what happened and what it means.

```
Känni (git ops)                    Kerto (knowledge graph)
─────────────                      ─────────────────────
commit → ────────────────────────→ vcs.commit occurrence
merge conflict → ────────────────→ context.learning occurrence
                                   "auth.go breaks when merged with session.go"
AI review → ─────────────────────→ context.decision occurrence
                                   "decided to use JWT over sessions"
branch deleted → ────────────────→ graph decay
                                   stale branch knowledge fades

query "why does auth break?" ←───← Kerto renders context
                                   "auth.go breaks login_test.go (weight 0.82)"
```

---

## 2. Occurrence Emission

Every meaningful Känni action emits a Kerto occurrence.

### Git Operations → Occurrences

```elixir
defmodule Känni.Kerto.Emitter do
  @moduledoc "Emits Kerto occurrences for git operations."

  alias Kerto.Ingestion.Occurrence

  def on_commit(repo_id, commit) do
    %Occurrence{
      type: "vcs.commit",
      source: :kanni,
      data: %{
        repo: repo_id,
        oid: commit.oid,
        message: commit.message,
        author: commit.author_name,
        files: commit.files |> Enum.map(& &1.path),
        timestamp: commit.timestamp
      }
    }
    |> Kerto.Engine.ingest()
  end

  def on_merge_conflict(repo_id, source, target, conflict_files) do
    %Occurrence{
      type: "context.learning",
      source: :kanni,
      data: %{
        subject_kind: :file,
        subject_name: hd(conflict_files),
        relation: :breaks,
        target_kind: :file,
        target_name: "#{source} → #{target} merge",
        evidence: "Merge conflict between #{source} and #{target} in #{Enum.join(conflict_files, ", ")}"
      }
    }
    |> Kerto.Engine.ingest()
  end

  def on_ai_review(repo_id, review) do
    for suggestion <- review.overall_suggestions do
      %Occurrence{
        type: "context.decision",
        source: :kanni,
        data: %{
          subject_kind: :concept,
          subject_name: suggestion.summary,
          relation: :decided,
          target_kind: :file,
          target_name: repo_id,
          evidence: suggestion.content
        }
      }
      |> Kerto.Engine.ingest()
    end
  end

  def on_ci_result(repo_id, task, status, changed_files) do
    type = if status == :failed, do: "ci.run.failed", else: "ci.run.passed"
    %Occurrence{
      type: type,
      source: :sykli,
      data: %{
        task: task,
        changed_files: changed_files,
        error: if(status == :failed, do: "CI failed", else: nil)
      }
    }
    |> Kerto.Engine.ingest()
  end
end
```

### Occurrence Types Känni Emits

| Känni Action | Kerto Occurrence | What Kerto Learns |
|---|---|---|
| Commit | `vcs.commit` | Co-changed files (`:often_changes_with`) |
| Merge conflict | `context.learning` | Which files conflict (`:breaks`) |
| Merge success | `ci.run.passed` | Weakens previous `:breaks` |
| AI review finding | `context.learning` | Risk patterns (`:caused_by`) |
| AI decision | `context.decision` | Architectural choices (`:decided`) |
| Branch delete (stale) | decay trigger | Old knowledge fades |

---

## 3. Kerto Context in Känni

When a user asks about a file or opens a repo, Känni queries Kerto for context.

### Contextual Enrichment

```elixir
defmodule Känni.Kerto.ContextProvider do
  @moduledoc "Enriches Känni views with Kerto knowledge."

  def enrich_diff(repo_id, files) do
    # For each file in a diff, ask Kerto what it knows
    files
    |> Enum.map(fn file ->
      case Kerto.Engine.context(:file, file.path) do
        {:ok, context} ->
          warnings = context
          |> Kerto.Rendering.Renderer.render()
          |> extract_cautions()

          Map.put(file, :kerto_warnings, warnings)

        _ ->
          file
      end
    end)
  end

  def enrich_commit_message(repo_id, staged_files) do
    # Ask Kerto about patterns in these files
    context = staged_files
    |> Enum.flat_map(fn file ->
      case Kerto.Engine.context(:file, file) do
        {:ok, ctx} -> ctx.relationships
        _ -> []
      end
    end)
    |> Enum.filter(fn rel -> rel.weight > 0.5 end)

    # Feed context to AI for better commit messages
    context
  end
end
```

### Chat Integration

```
you: show me the diff for feat/payments

känni: 3 files changed in feat/payments:

  • src/payments/handler.go (+45, -12)
    ⚠ Kerto: This file often breaks billing_test.go
       (weight 0.78, 8 observations)
       Last evidence: "CI failure: nil pointer on invoice creation"

  • src/payments/invoice.go (+20, -3)
    ★ Kerto: Decided to use Stripe API v2 (weight 0.85)

  • src/payments/types.go (+5, -0)
    No warnings.

  [Commit] [Show full diff] [Review with AI]
```

---

## 4. EWMA-Powered Branch Freshness

Use Kerto's EWMA to weight branch activity.

```elixir
defmodule Känni.Kerto.BranchHealth do
  @moduledoc "Uses EWMA to track branch freshness and health."

  def assess(repo_id, branch) do
    # Recent commits increase weight, time decays it
    commits = Känni.Git.Commands.log(repo_id, %{branch: branch, limit: 50})

    activity_weight = commits
    |> Enum.reduce(0.0, fn commit, acc ->
      age_days = DateTime.diff(DateTime.utc_now(), commit.timestamp, :day)
      observation = max(0.0, 1.0 - (age_days / 30.0))  # decays over 30 days
      Kerto.Graph.EWMA.update(acc, observation)
    end)

    # Check Kerto for known issues with this branch
    issues = case Kerto.Engine.context(:concept, "branch:#{branch}") do
      {:ok, ctx} ->
        ctx.relationships
        |> Enum.filter(& &1.relation in [:breaks, :caused_by])
      _ -> []
    end

    %{
      branch: branch,
      freshness: activity_weight,
      status: classify_freshness(activity_weight),
      known_issues: issues
    }
  end

  defp classify_freshness(weight) when weight > 0.7, do: :active
  defp classify_freshness(weight) when weight > 0.3, do: :stale
  defp classify_freshness(_), do: :abandoned
end
```

### Dashboard Display

```
Branch Health:
  main          ████████████  0.95  active
  feat/auth     ████████░░░░  0.72  active
  feat/old-api  ███░░░░░░░░░  0.25  stale    ⚠ breaks 2 tests
  hotfix/typo   █░░░░░░░░░░░  0.08  abandoned
```

---

## 5. Content-Addressed Identity

Känni uses Kerto's identity model for consistent entity identification.

```elixir
# Same file across repos, agents, and time = same Kerto node
Kerto.Graph.Identity.compute_id(:file, "src/auth/handler.go")
# → always the same hash, regardless of who references it

# This means:
# - Känni's diff mentions auth/handler.go
# - Sykli's CI mentions auth/handler.go
# - Claude Code agent mentions auth/handler.go
# All point to the SAME Kerto node. Knowledge accumulates.
```

---

## 6. Architecture

### Integration Layer

```
Känni.Kerto (integration module)
├── Emitter       — Emit occurrences on git operations
├── ContextProvider — Query Kerto for file/branch context
├── BranchHealth  — EWMA-powered branch assessment
└── Hooks         — PubSub listeners for automatic emission

# Hooks automatically emit on repo events:
Phoenix.PubSub.subscribe(Känni.PubSub, "repo:*")

def handle_info({:commit_created, commit}, state) do
  Känni.Kerto.Emitter.on_commit(state.repo_id, commit)
  {:noreply, state}
end
```

### Dependency Direction

```
Känni (application) → Kerto (library/service)

Känni knows about Kerto.
Kerto knows nothing about Känni.
Kerto is a library dependency, not a coupled system.
```

### Deployment Options

1. **Embedded**: Kerto runs as a dependency inside Känni's BEAM node (simplest)
2. **Daemon**: Kerto runs as a separate daemon, Känni connects via Unix socket
3. **MCP**: Känni talks to Kerto via MCP tools (most decoupled)

**Recommendation**: Start embedded (option 1). Kerto is designed as a library. Add daemon mode later if needed.

---

## 7. What This Enables

| Scenario | Without Kerto | With Kerto |
|---|---|---|
| "Why does auth break?" | Check git log manually | Kerto: "auth.go breaks login_test.go (weight 0.82, 8 observations)" |
| Merge feat/payments | Hope for the best | Kerto: "⚠ payments/handler.go has known conflicts with billing" |
| AI commit message | Based on current diff only | Based on diff + Kerto context (historical patterns, decisions) |
| New developer onboarding | Read docs, ask team | Kerto: "Here's what this codebase knows about itself" |
| Branch cleanup | Guess which are stale | EWMA weights show freshness objectively |
