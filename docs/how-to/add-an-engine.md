# How to add an engine

A host fronts one or more engines. An engine is a program that runs models and speaks the OpenAI HTTP dialect. A new host looks for Ollama at `http://127.0.0.1:11434`. Add another engine to use llama.cpp, LM Studio, vLLM, or a model server on another machine in your network.

## List the engines

```sh
tetrix-host engines
```

## Add a server that speaks the OpenAI API

Give the engine a short ID and its address.

```sh
tetrix-host engines add lmstudio http://127.0.0.1:1234
```

If the server needs a key, pass it.

```sh
tetrix-host engines add --key sk-local vllm http://10.0.0.20:8000
```

The engine's models then appear in `tetrix-host models` with the ID in front, for example `lmstudio/qwen3-8b`. Assign them to roles as usual.

An engine of this kind manages its own models. To download or delete a model, use the engine's own tools.

## Add a second Ollama

```sh
tetrix-host engines add --kind ollama studio http://10.0.0.30:11434
```

The host can download and delete models on an engine of kind `ollama`.

## Remove an engine

```sh
tetrix-host engines rm lmstudio
```

If a role used one of the engine's models, the host clears that role.

## Keep the engine private

The address you give is reachable by the host, not by paired devices. Devices reach models only through the host. If an engine runs on another machine, the traffic between the host and that engine is plain HTTP unless the address starts with `https://`, so keep both on a network you trust.
