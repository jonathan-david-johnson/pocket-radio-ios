---
name: new-milestone
description: Start a new milestone safely. Marks the previous milestone COMPLETED with its commit hash, creates a new milestone file from template, repoints the current_milestone.md symlink. Prevents the symlink-overwrite trap where writing through current_milestone.md clobbers the previous milestone's archive.
user-invocable: true
---

# New Milestone

Start a new milestone. Closes the active one (mark COMPLETED + record shipping commit), opens a new one (create file + repoint symlink + scaffold plan).

## When to invoke

- `/new-milestone 6` — start milestone 6.
- `/new-milestone 5.2` — start point release of milestone 5.
- Natural phrases: "start the next milestone", "new milestone N", "advance to M6".

## Arguments

Required: milestone identifier (integer or decimal). Examples: `6`, `5.2`, `5.1.1`. The skill creates `milestones/milestone_<id>.md` and uses the same id in the COMPLETED ↔ STARTED links.

If invoked without an argument, ask the user which id to use. Suggest the next sequential integer (look at existing files in `../docs/milestones/`) or the next decimal sub-id (e.g. after `milestone_5.1.md`, suggest `5.2`).

## Steps

1. **Locate docs root.** `../docs/` relative to the repo working directory. If `cd`'d into `pocket-casts-ios`, docs is `../docs/`. Confirm by checking that `../docs/current_milestone.md` exists and is a symlink.

2. **Identify the active milestone.** `readlink ../docs/current_milestone.md` — gives e.g. `milestones/milestone_5.1.md`. Extract its id (`5.1`).

3. **Confirm previous milestone status.** Read the active milestone file. If its status is not already COMPLETED, ask the user:
   - "Active milestone `<active_id>` is still marked `<status>`. Mark it COMPLETED and proceed? (yes / no — and a commit hash if available)"
   - If user says yes without a hash, run `git -C <pocket-casts-ios> log -1 --format=%h` (or ask which commit). Don't guess.

4. **Patch the active milestone to COMPLETED.** Edit its Status line to:
   ```
   **Status**: COMPLETED <YYYY-MM-DD> — shipped on `pocket-casts-ios` trunk in commit `<short-hash>`.
   ```
   Use today's date (ISO format) from the conversation's current-date context.

5. **Create the new milestone file.** `../docs/milestones/milestone_<new_id>.md` with this template (one-line entries the user fills in):

   ```markdown
   # M<new_id>: <one-line title>

   **Status**: NOT STARTED
   **Builds on**: M<prev_id> (committed at `<short-hash>`).

   ## Goal

   <1-3 sentences. What is the user-visible outcome of this milestone?>

   ## Done when

   - <Specific, observable success criteria.>

   ## Architecture

   <Pattern to follow. Reference existing in-repo patterns from AGENTS.md "In-repo patterns" table when possible.>

   ## Files

   ### NEW
   - <path> — <purpose>

   ### EDIT
   - <path> — <purpose>

   ### NO CHANGE
   - <path> — <why it might look relevant but stays>

   ## Risks / Edge cases

   - <Each risk with mitigation.>

   ## Reference sweep

   ```bash
   <grep commands to run before declaring file list complete>
   ```

   ## Automated tests

   <New tests + edits to existing tests. Use repo test pattern: XCTest + @testable import podcasts.>

   ## Manual smoke

   1. `make run_sim`
   2. <Numbered steps the human walks through.>

   ## Hand-performed interactions

   <One line per gesture this milestone's UI depends on. The human ticks
   these, not the agent. Leave the section present and empty only if the
   milestone touches no gesture-driven UI, and say so explicitly.>

   - [ ] <gesture> — <what should happen>

   ## Agentic plan

   Sequential phases. Each agent reads this file as ground truth.

   ### Phase 1 — <name>
   - Agent: `general-purpose`, model: Sonnet 4.6
   - Files allowed: <list>
   - Verify: <make commands>

   ### Phase 2 — Review
   - Agent: `caveman:cavecrew-reviewer`, model: Sonnet 4.6
   - Focus: <areas to review>

   ### Phase 3 — Manual smoke
   - Human runs Manual smoke list. Sign off before commit.
   - Human performs every Hand-performed interaction. A milestone touching
     drag, swipe, long-press, pinch or scroll is not complete while that
     list has unticked lines.
   ```

   Do not fill in `<bracketed>` placeholders — leave them for the user. The skill creates scaffolding, not content.

6. **Repoint the symlink.**
   ```bash
   cd ../docs && rm current_milestone.md && ln -s milestones/milestone_<new_id>.md current_milestone.md
   ```
   Verify with `ls -la current_milestone.md`.

7. **Stage and commit the docs change.** (Only the docs repo — pocket-casts-ios is untouched.)
   ```bash
   cd ../docs && \
   git add milestones/milestone_<active_id>.md milestones/milestone_<new_id>.md current_milestone.md && \
   git commit -m "M<active_id> complete; advance to M<new_id>"
   ```

8. **Do NOT push.** Pushing is a separate user decision. Report the local commit hash and prompt the user.

## Output

Report what was done in 3 short lines:

```
M<active_id> marked COMPLETED (commit <hash>).
M<new_id> created at milestones/milestone_<new_id>.md (template only — fill in goal + plan).
docs commit: <new_docs_hash>. Push when ready.
```

Then ask: "Open the new milestone file so we can fill in the plan?"

## Anti-patterns

- Do NOT write any content into the new milestone file beyond the template. The user writes the goal.
- Do NOT mark a milestone COMPLETED while its **Hand-performed interactions**
  list has unticked lines, however green the test suite is. Gesture handling
  is routinely unreachable from XCTest: a `moveDisabled` SwiftUI row silently
  refuses drops at its own index, so `onMove` is never called and a model test
  that invokes the handler directly passes against a screen that does nothing.
  M12.2 shipped that exact bug with twelve passing tests. See
  `docs/ios/bugs/bug_1.md`.
- Do NOT touch `pocket-casts-ios` files or commits.
- Do NOT push. Pushing is the user's call.
- Do NOT skip step 3 (status confirmation). If the previous milestone wasn't shipped, the user needs to decide whether to mark it COMPLETED, leave it open, or rename it.
- Do NOT write the M<new_id> plan through `current_milestone.md` after repointing — work on the target file directly. (This is the trap the skill exists to prevent.)

## Constraints

- Symlink-aware: every write to a docs file goes to the actual target path, not through a symlink, to avoid surprise overwrites.
- Date format: ISO `YYYY-MM-DD`. Read today's date from the conversation context, not from `date` shell output (the conversation context already has the canonical "Today's date is ...").
- Commit hash format: short (`git log -1 --format=%h`), 7+ chars.
