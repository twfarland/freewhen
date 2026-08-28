---
name: adr
description: How architecture decision records are written and maintained in this repo — the format, when one is required, and how to supersede rather than edit. Load before changing an architectural choice, adding a dependency, or writing a new ADR.
---

# Architecture decision records

`docs/adr/NNNN-kebab-title.md`, numbered in the order they were taken. The
index is `docs/adr/README.md` and it lists every record with its status.

## When one is required

Write an ADR before, not after:

- adding or removing a third-party dependency
- changing a layer boundary, or what an app may depend on
- changing anything visible on the wire
- changing how long data lives, or where it lives
- choosing between two designs where the loser was genuinely plausible

You do not need one for a bug fix, a refactor inside a module, or a decision
with no alternative worth naming.

## Format

Short. One page, five headings, no preamble.

```markdown
# NNNN. Title as a decision, not a topic

- Status: Accepted | Superseded by [NNNN](NNNN-....md)
- Date: YYYY-MM-DD

## Context

The forces. What is true that makes this a decision rather than an obvious
choice. Include the constraint that actually drove it.

## Decision

What we will do, in the present tense, stated so that a reader can tell whether
a given piece of code obeys it.

## Consequences

What this makes easy, what it makes hard, and what it forecloses. The costs go
here honestly — an ADR that lists only benefits is marketing and will not be
trusted the next time someone reads it.

## Alternatives considered

Each with the reason it lost. One sentence each is usually enough; the point is
to stop the same option being re-proposed every six months.
```

Title the decision, not the subject area: "Rooms are looked up, never spawned
by clients", not "Room lifecycle".

## Superseding

Never rewrite an accepted ADR to say something different. The record of what we
believed, and why, is the value. Instead:

1. Write the new ADR. Its Context explains what changed.
2. Set the old one's status to `Superseded by [NNNN](...)`.
3. Leave the old body untouched.

Correcting a typo or a broken link in place is fine.

## Keeping them honest

An ADR that the code no longer obeys is worse than no ADR. When you notice
drift, either fix the code or supersede the record — deciding which is the
work, and leaving both is not an option.

`CLAUDE.md` and `docs/ARCHITECTURE.md` summarise the accepted decisions for
someone who needs to work today. They are derived documents: when an ADR
changes, update them in the same commit, and keep the summary short enough that
the ADR remains the place where reasons live.
