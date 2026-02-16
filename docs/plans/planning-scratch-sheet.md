---
tags: [meta]
updated: 2026-02-15
---
# Planning Scratch Sheet

Raw idea dump and staging area. Items here get refined into plan docs when ready. See [roadmap.md](./roadmap.md) for the organized view.

When an item graduates to a plan doc, replace it with a link.

---

## Completed Plans (for reference)

- [Agent SDK Migration](./completed/agent-sdk-migration.md) — OpenClaw to Agent SDK + DOKS
- [GitHub Access Broker](./completed/agent-cluster-github-access-broker.md) — Token broker architecture
- [GitHub Access Broker Implementation](./completed/github-access-broker-implementation.md) — Step-by-step execution
- [Lobster Reliability](./completed/lobster-reliability.md) — Verify-retry loop

---

## Capabilities to research
- GitHub mcp
- unity mcp
- android studio mcp
- `mise.jdx.dev` or similar for managing tool dependencies in lobsters?
- `github.com/kulesh/catsyphon` for getting more insight into our own claude usage?

## Lobster updates
- Variants
	- ghidra lobster (isolated malware scans of binaries, general purpose reverse engineering tasks, vtable recreation and method naming, editing and rebuilding binaries, creating documentation for undocumented reverse engineered software)
	- Xcode lobster (how to manage licensing?, device tunneling)
	- Arduino lobster (platform.io in vscode user accessible, simulation, serial comms tunneling)
	- PCB design lobster (kicad, models with image processing, spice simulation, pcb manufacturer understanding, etc)
	- Home Assistant lobster (this should possibly be a whole separate project, but maybe an IoT-SwissArmyKnife lobster?)
- device tunneling for Lobsters that deploy to device hardware (android, Xcode, Arduino)?
- test flows for lobster variants' specific abilities
- allow lobsters to identify missing tools that they need, install them, have a process for ensuring these make it back into the lobster container's install requirements

## Vault updates

See [Vault Scaling & Sync](./active/vault-scaling.md)

## lobmob general updates

See [System Maintenance Automation](./draft/system-maintenance-automation.md)

## Lobster management
- lobboss or lobsigliere settings to keep some number of lobsters warm (permanently? On time delay after usage?) with notes on cost per day / month
- make each node capable of being user ssh'd into to work directly with claude code in the container

## Task flow updates

See [Task Flow Improvements](./draft/task-flow-improvements.md)

## How to enable lobmob to self improve?
- The basic flow would be: recognizing that a task failed, understand why, devise plans to fix, modify deployment scripts, redeploy, retry task
	- How to ensure this converges instead of getting off track and burning credits, or creating a bigger mess than the initial failure?
- How to understand what functionality will be better handled by a nondeterministic LLM vs more deterministic scripts, cron, daemons?

## User interfaces

### Discord

See [Discord UX Overhaul](./draft/discord-ux.md)

### Web UI / VSCode (not yet planned)
- WAN access
	- oauth login to access sidecar sites securely
	- central dashboard site with summary of all nodes, links to sidecars, etc
		- Who hosts this? lobboss?
- Lobsigliere
	- vscode for lobsigliere
- Lobboss
	- user interface into the vault with vscode?
- VSCode remoting?
