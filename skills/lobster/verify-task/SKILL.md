---
name: verify-task
description: Verify a SWE lobster's PR by reviewing code, running tests, and reporting pass/fail
---

# Verify Task

Use this skill when you've been assigned a task with `type: qa`. You'll verify a SWE lobster's code changes by reviewing the PR, running tests, and reporting results.

## 1. Receive and Read

1. You'll be notified of your assignment in the task's Discord thread.
2. Pull the vault: `cd /opt/vault && git pull origin main --rebase`
3. Read the QA task file at `010-tasks/active/<task-id>.md`
4. Note the key fields:
   - `related_task:` — the SWE task being verified
   - `pr_number:` — the PR to review
   - `repo:` — which repo the PR is on

## 2. Acknowledge

Post in the task's Discord thread:
```
ACK <task-id> <your-lobster-id> — starting verification
```

## 3. Checkout the PR

```bash
cd /opt/lobmob   # or the target repo directory
git fetch origin
gh pr checkout <pr_number>
```

## 4. Code Review

Review the diff:
```bash
gh pr diff <pr_number>
```

Check for:
- [ ] Code quality and style consistency with existing patterns
- [ ] Potential bugs, edge cases, or regressions
- [ ] Security issues (secrets in code, command injection, unsafe operations)
- [ ] Adherence to the task's acceptance criteria (read the related SWE task file)
- [ ] Test coverage — are the changes tested?
- [ ] No unnecessary changes outside the task scope

## 5. Run Tests

```bash
cd /opt/lobmob

# Run the full test suite
PASS=0; FAIL=0
for test in tests/*; do
  echo "=== $test ==="
  if bash "$test" 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
done
echo "Tests: $PASS passed, $FAIL failed"

# Lint changed shell scripts
CHANGED=$(gh pr diff <pr_number> --name-only | grep -E '\.(sh|bash)$|^scripts/' || true)
for script in $CHANGED; do
  if [ -f "$script" ]; then
    echo "=== shellcheck $script ==="
    shellcheck "$script" 2>&1 || true
  fi
done
```

## 6. Determine Verdict

- **PASS** — Code looks good, all tests pass, no issues found
- **PASS WITH NOTES** — Tests pass but there are minor observations (not blockers)
- **FAIL** — Tests fail, bugs found, or acceptance criteria not met
- **BLOCK** — Security issues found, or changes that could cause data loss/system instability

## 7. Update Vault Task File

Update your QA task file (`010-tasks/active/<qa-task-id>.md`):
- Set `status: completed` and `completed_at`
- Fill in **Result** with your verdict, recommendation (MERGE/REQUEST CHANGES/BLOCK), and key findings
- Fill in **Lobster Notes** with:
  - Code review findings (bullet list)
  - Test results (N passed, M failed, details of failures)
  - Shellcheck results
  - Security review notes

The task-watcher cron will detect your status change and post to Discord automatically.

Submit a vault PR:
```bash
cd /opt/vault
git checkout main && git pull origin main --rebase
git checkout -b lobster-<id>/task-<qa-task-id>
git add 010-tasks/
git commit -m "[lobster-<id>] Verify task-<related-task-id>: <PASS|FAIL>"
git push origin lobster-<id>/task-<qa-task-id>
gh pr create --title "QA: task-<related-task-id> — <PASS|FAIL>" --body "<summary>" --base main
```

## Important Rules

- You do NOT modify code in the target repo — only review and test
- Do NOT merge or close the SWE PR — that's lobboss's job
- Report objectively — note both strengths and issues
- If tests fail, provide clear reproduction steps
- If you find security issues, always report as BLOCK
- Return to `develop` branch when done: `cd /opt/lobmob && git checkout develop`
