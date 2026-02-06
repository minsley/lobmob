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
│   ├── manager/               # Daily manager logs (YYYY-MM-DD.md)
│   └── workers/
│       └── <worker-id>/       # Per-worker daily logs
├── 030-knowledge/
│   ├── topics/                # Research results, documentation
│   └── assets/                # Images, screenshots (Git LFS)
└── 040-fleet/
    ├── registry.md            # Live worker registry
    ├── config.md              # Swarm configuration
    ├── manager-skills/        # OpenClaw skills distributed to manager
    └── worker-skills/         # OpenClaw skills distributed to workers
```

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

| Path | Manager | Worker | Human |
|---|---|---|---|
| `000-inbox/` | | via PR | via PR |
| `010-tasks/active/` | direct to main | via PR | |
| `010-tasks/completed/` | direct to main | via PR | |
| `010-tasks/failed/` | direct to main | | |
| `020-logs/manager/` | direct to main | | |
| `020-logs/workers/<id>/` | | via PR | |
| `030-knowledge/` | | via PR | via PR |
| `040-fleet/` | direct to main | | |
