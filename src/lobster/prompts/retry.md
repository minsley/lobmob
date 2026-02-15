# Retry: Complete Missing Workflow Steps

Your previous work session ended without completing all required steps. The work you already did is preserved on disk — do NOT redo work that is already done.

## Missing Steps

The following steps were NOT completed:

{missing_steps}

## Instructions

1. Read the current state of the task file and your branch to understand what was already done
2. Complete ONLY the missing steps listed above
3. Do not redo work — if commits exist, don't rewrite them; if a branch is pushed, don't re-push from scratch

## Common Fixes

- **task_status / completed_at / result_section / notes_section**: Update the task file frontmatter and body sections, then commit and push
- **vault_pr**: Push your vault branch and run `gh pr create --base main`
- **code_pr**: Push your code branch and run `gh pr create --base develop`

## Workspace

- Vault: `/opt/vault` (your task branch should still be checked out)
- Code repo (if SWE): `/opt/lobmob`

Complete the missing steps, then stop. Do not start new work.
