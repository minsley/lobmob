---
status: draft
tags: [lobster, variants, homeassistant, iot, automation]
maturity: research
created: 2026-02-23
updated: 2026-02-23
---
# Lobster Variant: Home Assistant / IoT

## Summary

Lobster (or possibly a separate lobmob deployment) for IoT and home automation tasks — interfacing with a Home Assistant instance, writing automations, managing integrations, MQTT workflows, and general IoT device work. The scratch sheet notes this may warrant being a whole separate project rather than a lobster variant. That question is the primary open issue.

## The Scope Question

There are two very different interpretations:

**A) Lobster variant**: a lobmob-lobster-homeassistant image with HA client libraries. Lobster tasks interface with an existing Home Assistant instance via its REST/WebSocket API. Useful for: writing automations, debugging integrations, generating HA configuration YAML.

**B) Separate IoT-SwissArmyKnife project**: a lobmob-style agent swarm dedicated to home automation management. lobboss equivalent manages HA, lobster equivalents handle individual automation tasks, physical device access built in from the start. Much larger scope.

**Working assumption**: start with Option A (lobster variant) since it requires no new infrastructure. Revisit Option B if the use case expands beyond what a lobster can reach.

## Toolchain (Option A)

| Tool | Purpose | Notes |
|---|---|---|
| `homeassistant` Python client (`hass-client`) | REST + WebSocket API | Query state, call services, subscribe to events |
| `paho-mqtt` | MQTT pub/sub | Direct MQTT access for IoT devices |
| `aiohttp` | Async HTTP | Already likely in base image |
| `zigpy` / `zigpy-znp` | Zigbee protocol stack | For direct Zigbee integration (advanced) |
| `python-zwave-js` | Z-Wave | For direct Z-Wave integration (advanced) |
| HA YAML validator | Config validation | `homeassistant --script check_config` |

## Open Questions

- [ ] **Separate project vs lobster variant?** The scope and access model are fundamentally different. A lobster variant can only reach HA over the network; a dedicated project could run alongside HA on local hardware.
- [ ] **Network access**: lobsters run in cloud k8s. A home HA instance is on a local LAN. How does a cloud lobster reach a local HA instance? Options: HA Cloud (Nabu Casa), Cloudflare Tunnel, Tailscale, or the lobster is local (k3d/lobsigliere node on the same LAN).
- [ ] **HA credentials**: Long-Lived Access Token or OAuth. Goes in `secrets-local.env` / `secrets.env`. Different token per environment?
- [ ] **Local-only use case?**: HA access may only make sense in the local overlay (lobmob on the same LAN as HA). Cloud deployment can't reach a home LAN without tunneling.
- [ ] **Direct device protocols** (Zigbee, Z-Wave): requires USB dongle access — same hardware access problem as Arduino/Xcode. Probably out of scope for a cloud lobster.

## Phases

### Phase 0: Scope decision
- Decide: lobster variant (Option A) or separate project (Option B)
- Decide: local-only or cloud-accessible via tunnel

### Phase 1: Base image (if Option A)
- `containers/lobster-homeassistant/Dockerfile`
- Install HA Python client, paho-mqtt, HA config validator
- Smoke test: connect to HA API, list entities

### Phase 2: Local overlay integration
- Add to `k8s/overlays/local/` if local-only
- HA URL and token in `secrets-local.env`

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-23 | Defer scope decision | Two valid paths; local overlay plan needs to land first to understand local lobster capabilities |

## Scratch

- HA REST API: `GET /api/states`, `POST /api/services/{domain}/{service}` — simple and well-documented
- HA WebSocket API: better for event subscriptions and real-time state
- `hass-client` PyPI package wraps both
- Nabu Casa / HA Cloud gives remote access to local HA instance ($7/mo) — simplest tunnel option
- Tailscale also works: lobster joins Tailscale network, HA host also on Tailscale
- Local-only angle: if lobmob runs on k3d on the same machine/LAN as HA, no tunnel needed
- IoT Swiss Army Knife concept is interesting but is essentially a second lobmob — staffing cost and infra overhead warranted only if the use case is deep enough

## Related

- [Lobster Variants overview](./lobster-variants.md)
- [Local overlay](./local-overlay.md) — local deployment may be prerequisite for HA access
- [Lobster Arduino](./lobster-arduino.md) — overlapping IoT/hardware territory
