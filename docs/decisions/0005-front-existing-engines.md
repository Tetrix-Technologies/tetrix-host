# 5. Front existing engines instead of running models in the host

Status: accepted, 2026-11-11

## Context

Something must load model weights and run them on the machine's processor or graphics card. Good open source programs already do this on every platform: Ollama, llama.cpp, LM Studio, vLLM, MLX. They all speak the OpenAI HTTP dialect.

## Decision

The host does not run models. It forwards each request to an engine on the same machine or network and streams the answer back. It knows two kinds of engine: `ollama`, which it can also ask to download and delete models, and `openai`, which is any server that speaks the dialect.

A new host looks for Ollama at its default address.

## Alternatives

Linking llama.cpp or MLX into the host would make one install. It would also tie the host's releases to a fast-moving inference library, add a C++ or Python toolchain to the build, and fix the choice of runtime for every platform.

Bundling an engine with the Mac app is a packaging step, not a design change, and can come later.

## Consequences

- The host is small and builds in seconds.
- A person installs two things: an engine and the host.
- What a model can do, such as tool calls or structured output, depends on the engine. The host passes requests through and reports each model's capabilities where the engine exposes them.
- Model downloads work through Ollama only. For another engine, the person uses that engine's own tools.
- An engine's defaults are not the host's. Ollama gives every model a 4,096-token window and cuts a longer request without an error, which made a paired app's requests useless. The host now asks Ollama for a variant of each model with the window it wants. It can do that for Ollama only.
