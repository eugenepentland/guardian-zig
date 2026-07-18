# Guardian Usage Feedback Log

Append-only log of real-world Guardian experience, written by whichever agent
(Claude, Codex/ChatGPT, or a human) just finished work in a Guardian-gated
project. Eugene reviews this list periodically and turns entries into Guardian
changes; the entries themselves are the triage backlog.

## How to add an entry (agents: follow this exactly)

1. Write the entry **at the bottom of the Log section** — never edit, reorder,
   or delete existing entries (pruning happens at triage, by Eugene only).
2. Make it self-contained: another agent (or Eugene, weeks later) has none of
   your session context. Name the check, the project, what happened, and what
   it cost you (retries, wasted builds, confusion).
3. Commit the append in this repo immediately, so the tree stays clean:

   ```bash
   git -C ~/ai/canopy/guardian-zig add FEEDBACK.md
   git -C ~/ai/canopy/guardian-zig commit -m "feedback: <project> — <one-liner>"
   ```

4. A smooth session is signal too — a one-line `good:` entry is enough.
   Skip logging only when the session never touched a Guardian gate.

### Entry format

```markdown
## YYYY-MM-DD · <agent> · <project> — <task one-liner>
- **friction:** <what slowed you down — check name, what happened, cost>
- **bug:** <behavior that looks wrong, with repro if cheap>
- **good:** <what worked well / caught a real mistake>
- **wish:** <feature or change that would have helped>
```

Use only the bullet kinds you have something to say about. Multiple bullets of
the same kind are fine.

---

## Log
