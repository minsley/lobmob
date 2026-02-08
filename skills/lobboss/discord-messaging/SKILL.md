---
name: discord-messaging
description: Reference patterns for posting messages, creating threads, and replying in threads on Discord
---

# Discord Messaging

Use the `message` tool for all Discord communication. This skill documents the
common patterns. Other skills reference this for posting instructions.

## Channels

| Channel | Purpose |
|---|---|
| **#task-queue** | Task lifecycle — one parent message per task, updates in threads |
| **#swarm-control** | User commands to lobboss (fleet management) |
| **#swarm-logs** | Fleet events (spawns, merges, convergence, status) |

## Agent Name Prefix

All Discord messages MUST start with your agent name in bold brackets so humans
can tell who posted. The bot username is shared across all agents.

| Agent | Prefix |
|---|---|
| lobboss | `**[lobboss]**` |
| lobster | `**[lobster-<your-id>]**` |
| watchdog | `**[watchdog]**` |

Example: `**[lobboss]** Task created: **task-2026-02-07-a1b2**`

## Sending a Message to a Channel

Use the `message` tool with action `send`:

```json
{
  "action": "send",
  "channel": "discord",
  "to": "channel:CHANNEL_ID",
  "text": "Your message here"
}
```

Channel IDs:
- **#task-queue**: `1469216767363780690`
- **#swarm-control**: `1469216903355568181`
- **#swarm-logs**: `1469216945764175946`

The response includes a `messageId` — save it if you need to create a thread on this message.

## Creating a Thread

After sending a parent message, create a thread on it:

```json
{
  "action": "thread-create",
  "channel": "discord",
  "to": "channel:CHANNEL_ID",
  "messageId": "<parent-message-id>",
  "text": "First message in the thread",
  "threadName": "Task: <short title>"
}
```

The response includes a `threadId` — save it for all subsequent replies.

## Replying in a Thread

Post a follow-up message in an existing thread:

```json
{
  "action": "thread-reply",
  "channel": "discord",
  "threadId": "<thread-id>",
  "text": "Your reply here"
}
```

## Editing a Message

Update an existing message (e.g. to update a parent message with task status):

```json
{
  "action": "edit",
  "channel": "discord",
  "to": "channel:CHANNEL_ID",
  "messageId": "<message-id>",
  "text": "Updated content"
}
```

## Common Patterns

### Task Thread Pattern (used by task-lifecycle skill)

1. Send a parent message to #task-queue with the task proposal
2. Create a thread on the parent message named "Task: <title>"
3. All discussion (confirmation, assignment, progress, results) goes in the thread
4. Store `discord_thread_id` in the task file frontmatter so lobsters can post to it

### Fleet Event Pattern (used by spawn, teardown, fleet-status skills)

Send a single message to #swarm-logs. No thread needed.

### Swarm Command Pattern (used in #swarm-control)

Respond directly in the channel to user commands. Use threads only if a long
back-and-forth is needed.
