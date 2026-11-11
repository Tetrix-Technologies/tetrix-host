# 4. Apps ask for a role, and the owner maps roles to models

Status: accepted, 2026-11-11

## Context

Tetrix apps already split their work. Cue sends planning and tool use to a larger model, and yes-or-no decisions to a much smaller, faster one. The split is part of why the apps feel quick.

On a person's own hardware, the right models depend on the machine. An app cannot know them.

## Decision

A host defines two roles. **Deep** is for work that needs thought. **Quick** is for short, simple work. An app sets `"model"` to `"deep"` or `"quick"`. The host's owner assigns a model to each role and can change it at any time.

If no model is assigned to quick work, the deep model serves both. That is how an owner uses one model for everything.

When a host with no assignment first sees installed models, it assigns the largest to deep work and the smallest to quick work.

An app can still name a model ID, for tools and tests.

## Alternatives

Apps name models, and the host maps names. Every app would then carry a list of models, and the owner would need to keep aliases for each.

More roles, such as vision, embedding, or code. They can be added when an app needs one. Two covers what Cue does today.

Automatic routing, where the host picks a model per request by looking at it. The app already knows what kind of work it has. Guessing again on the host adds latency and surprises.

## Consequences

- An app works on any host without changes, and an owner can swap models without touching an app.
- `GET /v1/host` tells an app what each role's model can do, so an app can check for tool use before it relies on it.
- A model that is too weak for an app's deep work fails in the app, not at assignment. `tetrix-host doctor` notes when the deep model cannot call tools.
