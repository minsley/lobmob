# Vault Structure

The lobmob vault is an Obsidian-compatible repository of markdown files used
for task tracking, work logging, and knowledge persistence across the swarm.

## Directory Layout

```
lobmob-vault/
├── .obsidian/templates/       # Obsidian templates for new files
├── 000-inbox/                 # Raw dumps, unsorted findings
├── 010-tasks/
│   ├── active/                # Tasks currently queued or being worked
│   ├── completed/             # Successfully finished tasks
│   └── failed/                # Tasks that couldn't be completed
├── 020-logs/
│   ├── lobboss/               # Daily lobboss logs (YYYY-MM-DD.md)
│   └── lobsters/
│       └── <lobster-id>/      # Per-lobster daily logs
├── 030-knowledge/
│   ├── topics/                # Research results, documentation
│   └── assets/                # Images, screenshots (Git LFS)
└── 040-fleet/
    ├── registry.md            # Fleet registry — active lobsters and their state
    └── config.md              # Swarm configuration (scaling, model routing)
```

## Automated Scanning

### Lobsigliere Daemon

The lobsigliere background daemon polls the vault every 30 seconds and scans:

**Directory:** `010-tasks/active/`

It reads every `*.md` file in that directory and looks for YAML frontmatter matching:
- `type: system`
- `status: queued`

When a matching task is found, the daemon:
1. Claims it atomically (sets `status: system-active`, pushes to vault)
2. Executes via Agent SDK in the lobmob workspace
3. Creates a branch and PR to `develop`
4. Updates the task file with results (`status: completed` or `status: failed`)

### Task Manager CronJob

The `task-manager` CronJob runs every 5 minutes and scans the same `010-tasks/active/`
directory for non-system tasks (`type: swe`, `research`, `qa`) with `status: queued`.
It assigns these to lobster workers via lobboss.

## Conventions

### Frontmatter
All files use YAML frontmatter for metadata. Templates in `.obsidian/templates/`.

### Wikilinks
Use `[[page-name]]` to link between vault pages. This enables Obsidian's
graph view and backlinks.

### File Naming
- Tasks: `task-YYYY-MM-DD-<4hex>.md`
- Logs: `YYYY-MM-DD.md`
- Knowledge: descriptive kebab-case (`llm-pricing-comparison.md`)

### Assets
Images and binary files go in `030-knowledge/assets/<topic>/`.
Tracked with Git LFS via `.gitattributes`.
Referenced from markdown: `![[assets/<topic>/image.png]]`

## Who Writes Where

| Path | Lobboss | Lobster | Lobsigliere | Human |
|---|---|---|---|---|
| `000-inbox/` | | via PR | | via PR |
| `010-tasks/active/` | direct to main | via PR | direct to main (status updates) | |
| `010-tasks/completed/` | direct to main | via PR | | |
| `010-tasks/failed/` | direct to main | | direct to main | |
| `020-logs/lobboss/` | direct to main | | | |
| `020-logs/lobsters/<id>/` | | via PR | | |
| `030-knowledge/` | | via PR | | via PR |
| `040-fleet/` | direct to main | | | |
