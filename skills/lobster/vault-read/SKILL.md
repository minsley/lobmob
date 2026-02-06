---
name: vault-read
description: Pull the latest vault state and read files
---

# Vault Read

Use this to get the latest information from the shared vault before starting
or during a task.

## Pull Latest
```bash
cd /opt/vault
git checkout main
git pull origin main
```

## Read a File
```bash
cat /opt/vault/<path>
```

## Search the Vault
```bash
# Find files by name
find /opt/vault -name "*.md" | grep -i "<keyword>"

# Search file contents
grep -rl "<keyword>" /opt/vault/030-knowledge/
```

## Follow Wikilinks

If a file contains `[[some-page]]`, the linked file is at:
- `030-knowledge/topics/some-page.md` (most common)
- Or search: `find /opt/vault -name "some-page.md"`

## Read Your Task Assignment
```bash
cat /opt/vault/010-tasks/active/<task-id>.md
```

## Check Fleet Registry
```bash
cat /opt/vault/040-fleet/registry.md
```

## Important
- Always pull before reading to get the latest state
- The vault is a shared resource — other lobsters may have updated files
- Do not modify files on the main branch directly — use your task branch
