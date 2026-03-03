# Känni — Context Exchange Surface for Agentic Work

> *känni* (Finnish): a turning point, a heel turn

## One-Liner

Känni is where you see what your agents know, what they're doing, and what needs your decision.

## The Problem

You work with AI agents across multiple repositories. Claude Code, Cursor, Copilot — they're making changes, learning things, accumulating context. But you can't see any of it.

Right now your workflow is:

```
Terminal 1: Claude Code working on kerto
Terminal 2: Claude Code working on sykli
Terminal 3: you, running git status in each repo, reading diffs, trying to keep up
```

You're blind to three things:

1. **What agents know.** Kerto accumulates knowledge — "auth.go breaks login_test.go (82% confidence)" — but you never see it. It flows between agents and a graph invisibly.

2. **What agents are doing.** You find out what happened after the fact, by reading diffs. No live awareness of work in progress.

3. **What needs you.** Agents hit decision points — design choices, conflict resolution, risk assessment — and you don't know until you check.

The result: you spend more time context-switching and catching up than actually conducting the work.

## What Känni Is

Känni is the **surface** where context becomes visible and actionable.

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   Agents          Känni              You                    │
│   (workers)       (surface)          (conductor)            │
│                                                             │
│   Claude Code ──→ ┌─────────┐                               │
│   Cursor     ──→ │ context  │ ──→ see what's known          │
│   Copilot    ──→ │ exchange │ ──→ see what's happening      │
│                   │ surface  │ ──→ decide what matters       │
│   Kerto      ──→ │          │ ──→ act (commit, push, steer) │
│   Sykli      ──→ └─────────┘                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

Three layers:

| Layer | What you see | Source |
|-------|-------------|--------|
| **Context** | What agents know about your projects — patterns, risks, decisions, relationships | Kerto knowledge graph |
| **Activity** | What's happening right now — changes, operations, agent work | Git state + file watching |
| **Action** | What you can do — commit, push, review, steer | Git operations via Rust NIF |

Git is the **medium**, not the product. Commits, branches, diffs — these are artifacts of agentic work. Känni shows them with context, not in isolation.

## What Känni Is Not

- Not a git GUI with AI bolted on
- Not a replacement for `git` CLI (you'll still use it)
- Not a code review tool (though it shows reviews)
- Not an agent manager (agents are independent)
- Not a dashboard you check — a surface you inhabit

## The Relationship with Kerto

Kerto is the **memory**. Känni is the **surface**.

```
Kerto (invisible)              Känni (visible)
────────────────               ───────────────
stores knowledge     ────→     renders knowledge
accumulates patterns ────→     shows patterns forming
receives learnings   ────→     shows what was learned
decays old context   ────→     shows what's fading
```

Without Känni, Kerto is a database that only agents see. With Känni, the human sees the same context agents see — and can shape it.

This is the "equip, don't police" philosophy applied to the human side. You're not reviewing agent output suspiciously. You're seeing the full picture so you can conduct better.

## The Compound Effect

```
Day 1:    You see repo states and recent changes
Week 1:   You see Kerto patterns forming — which files are risky, which change together
Month 1:  You see the full context landscape — decisions, patterns, agent learnings
Month 6:  Känni is how you think about your projects, not just how you manage git
```

## Design Principles

1. **Context over commands.** Show what's known, not what's possible.
2. **Awareness over control.** You see everything, you act on what matters.
3. **Git is the medium.** Every view is grounded in git state, enriched with Kerto context.
4. **Real-time, not refresh.** Changes flow in as they happen.
5. **Keyboard-first.** Terminal-inspired, information-dense, fast.
6. **Equip, don't police.** Trust agents, see their work, conduct the orchestra.

## The Ecosystem

```
You ←──── Känni (surface) ←──── Kerto (memory)
                                  ↑
                           Sykli (CI) ──→ "tests failed because..."
                           Git hooks  ──→ "these files changed together"
                           Agents     ──→ "I learned that X causes Y"
```

Känni is how you inhabit the False Systems stack. Everything else feeds context in. Känni makes it visible so you can act on it.

---

**False Systems** | *känni* — see what your agents know.
