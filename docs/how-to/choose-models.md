# How to choose models

A host hands out two kinds of work. Deep work needs thought: planning a task, writing, using tools. Quick work is short: a yes-or-no decision, a one-line rewrite. You assign a model to each, or one model to both.

## See what is installed

```sh
tetrix-host models
```

The `CAN` column shows what each model does beyond chat. An app that acts on your behalf needs a deep model that lists `tools`.

## Download a model

```sh
tetrix-host models pull qwen3:8b
```

The name is the engine's name for the model. For Ollama, find names in the [Ollama library](https://ollama.com/library). Press Ctrl-C to stop a download. A stopped download resumes the next time you pull the same model.

In the Mac app, open the inspector and click **Download a model**.

## Use a larger model for deep work and a smaller one for quick work

```sh
tetrix-host use deep qwen3:14b
tetrix-host use quick gemma3:4b
```

This is the setup Tetrix's own apps are built around. The quick model answers in a fraction of the time, and most requests are quick ones.

## Use one model for everything

```sh
tetrix-host use qwen3:8b
```

Choose this if the machine cannot hold two models in memory at once. An engine that swaps models in and out for each request is slower than one model that stays loaded.

## Pick sizes that fit the machine

A model must fit in memory with room left for the system. As a rule, keep the models that are loaded at the same time under two thirds of the machine's memory. On a PC, the limit is the graphics card's memory, not the system's.

| Memory | Deep work | Quick work |
|--------|-----------|------------|
| 8 GB | A 4B model | The same model |
| 16 GB | An 8B model | A 1B to 4B model |
| 32 GB | A 14B to 20B model | A 4B model |
| 64 GB or more | A 30B model or larger | An 8B model |

Sizes are parameter counts at 4-bit quantization. The table is a starting point. Try a model with `tetrix-host chat` before you rely on it.

## Give a model enough room

A model reads a request through a window of a fixed size, counted in tokens. A request that does not fit is cut to fit, with no error. The answer looks normal and ignores most of what was asked.

Left alone, Ollama gives every model 4,096 tokens. An app that sends tools and a long conversation needs several times that. So the host sets the window itself, per kind of work:

| Kind of work | Default window |
|--------------|----------------|
| Deep | 32,768 tokens |
| Quick | 8,192 tokens |

A model never gets more than it supports. One model that serves both kinds of work runs with the deep window.

To see the windows, and to change one:

```sh
tetrix-host window
tetrix-host window deep 65536
tetrix-host window quick default
```

A larger window uses more memory, often more than the model's own size. A 0.5 GB model with a 32,768-token window took 4.3 GB on the machine these docs were written on. If a model stops loading after you raise its window, lower the window or pick a smaller model. `tetrix-host models` shows the window each loaded model runs with.

To leave a window to the model server, use `engine`:

```sh
tetrix-host window deep engine
```

The host sets the window by asking Ollama for a variant of the model, named after the model with a suffix such as `-th32768`. A variant takes no extra disk space. `ollama list` shows it. The host does not list it, and deletes it when you delete the model.

The host can set the window on an Ollama engine only. For another engine, use that engine's own setting.

## Delete a model

```sh
tetrix-host models rm qwen3:0.6b
```

If a role used the model, the host clears that role. Assign another model, or apps that ask for the role get an error.
