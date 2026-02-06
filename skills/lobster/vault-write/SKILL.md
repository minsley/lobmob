---
name: vault-write
description: Write files to the vault on your task branch
---

# Vault Write

All writes happen on your task branch, never directly on main. Your changes
reach main only after the lobboss merges your PR.

## Setup (once per task)
```bash
cd /opt/vault
git checkout main && git pull origin main
git checkout -b "lobster-${LOBSTER_ID}/task-${TASK_ID}"
```

## Writing Files

### Results / Knowledge
```bash
# Create or update a knowledge page
cat > /opt/vault/030-knowledge/topics/<name>.md <<'EOF'
---
created: <ISO date>
author: lobster-${LOBSTER_ID}
task: ${TASK_ID}
tags: [<relevant>, <tags>]
---

# <Title>

<Content with [[wikilinks]] to related pages>
EOF
```

### Images and Assets
```bash
mkdir -p /opt/vault/030-knowledge/assets/<topic>/
# Save images, screenshots, data files here
# Reference from markdown: ![[assets/<topic>/image.png]]
```

### Work Log
```bash
cat >> /opt/vault/020-logs/lobsters/${LOBSTER_ID}/$(date +%Y-%m-%d).md <<EOF

## $(date +%H:%M) — <activity>
<description of what you did>
EOF
```

### Task File Updates
```bash
# Edit the task file to update status, add notes
# Use sed or write the full file — just ensure frontmatter stays valid YAML
```

## Committing
```bash
cd /opt/vault
git add -A
git commit -m "[lobster-${LOBSTER_ID}] <short description>"
```

You can make multiple commits on your branch. The PR will include all of them.

## Pushing
```bash
git push origin "lobster-${LOBSTER_ID}/task-${TASK_ID}"
```

If you've already created a PR, pushing updates it automatically.

## Rules
- Never force-push
- Never commit secrets, API keys, or credentials
- Keep files in the correct vault directories
- Use descriptive commit messages prefixed with your lobster ID
