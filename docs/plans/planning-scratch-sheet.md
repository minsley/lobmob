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
- Obsidian kanban mode for tasks
- vault doing too much? should be a combined machine + user interface for creating and updating tasks, seeing results; but it's holding a lot of system state and logging that may be better as a database
	- Use central database?
	- Use message queues? pub/sub?
- Strategy for keeping vault state more real-time synced between all nodes accessing it
	- Frequent pull, merge, commit, push, repeat ?
		- Who resolves conflicts?
		- File locking?
	- Use existing Obsidian git plugin?
	- Have nodes set up file change listeners that respond to recent last-modified date?
		- Avoid acting on a doc being actively edited with a time window? eg. edited more than 60 seconds ago, but less than 5 minutes ago? Local store of lsat checked time per file?

## lobmob general updates
- regular audit and review runs for:
	- security
	- code maintenance
	- task maintenance
	- doc updating

## Lobster management
- lobboss or lobsigliere settings to keep some number of lobsters warm (permanently? On time delay after usage?) with notes on cost per day / month
- make each node capable of being user ssh'd into to work directly with claude code in the container

## Task flow updates
- task entry for lobmob sidecar website
- nice specific names for lobster k8s
- nice names for tasks, still with ID

## How to enable lobmob to self improve?
- The basic flow would be: recognizing that a task failed, understand why, devise plans to fix, modify deployment scripts, redeploy, retry task
	- How to ensure this converges instead of getting off track and burning credits, or creating a bigger mess than the initial failure?
- How to understand what functionality will be better handled by a nondeterministic LLM vs more deterministic scripts, cron, daemons?

## User interfaces
- Discord
	- We're not really using all our channels, and it's spammy as is. What's a better UX for user and bot interaction?
		- Can collapse down to one channel?
		- Can leverage threads or pinning more?
		- Would another channel format like Q&A be better?
		- Conversational? Ask about task statuses?
		- What gets pushed to discord by bot versus requested by discord user?
- Web UI
	- WAN access
		- oauth login to access sidecar sites securely
		- central dashboard site with summary of all nodes, links to sidecars, etc
			- Who hosts this? lobboss?
	- Lobsigliere
		- vscode for lobsigliere
	- Lobboss
		- user interface into the vault with vscode?
- VSCode remoting?
