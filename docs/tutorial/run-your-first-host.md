# Run your first host

In this tutorial we start a host on a Mac, give it two small models, talk to both from the terminal, and prove that a paired device can reach it through a sealed tunnel. It takes about ten minutes. At the end you have a working host and know the five commands you will use most.

You need a Mac with Apple silicon, [Homebrew](https://brew.sh), and about 1 GB of free disk space.

## Install the host

First, install the `tetrix-host` command.

```sh
brew install tetrix-technologies/tap/tetrix-host
```

Homebrew downloads the command and puts it on your `PATH`. Now check that your shell finds it.

```sh
tetrix-host version
```

You should see the name and a version.

```
tetrix-host 0.1.0
```

## Start an engine

The host does not run models itself. It fronts an engine that does. We use Ollama.

Install Ollama from [ollama.com/download](https://ollama.com/download) and open it. Check that it answers.

```sh
curl http://127.0.0.1:11434/api/version
```

You should see a version number in JSON.

## Start the host

Now start the host. It runs in this terminal until you press Ctrl-C.

```sh
tetrix-host serve
```

The last lines look like this. The host ID on your machine is different.

```
time=2026-11-11T12:28:55.382+10:00 level=INFO msg="made a new host identity" host=aoccscb7qz37b47z
time=2026-11-11T12:28:55.701+10:00 level=INFO msg=serving address=127.0.0.1:4784 host=aoccscb7qz37b47z
```

A third line says the tunnel is up. The host has dialed out to Tetrix's relay, which is how an app on another device will reach it.

Leave this terminal open, and open a second one for the rest of the tutorial.

## Download two models

A host has two kinds of work to hand out. Deep work needs thought and goes to a larger model. Quick work is short and goes to a smaller one.

We download a small model for each. These two are tiny, so they download in about a minute. They are not good enough for real work.

```sh
tetrix-host models pull qwen3:0.6b
tetrix-host models pull gemma3:270m
```

Each command shows its progress and ends with a line such as `Downloaded qwen3:0.6b.`

Now assign them.

```sh
tetrix-host use deep qwen3:0.6b
tetrix-host use quick gemma3:270m
tetrix-host models
```

The list shows which model does what.

```
MODEL               SIZE    USED FOR  CAN              IN MEMORY
ollama/gemma3:270m  0.3 GB  quick
ollama/qwen3:0.6b   0.5 GB  deep      tools, thinking
```

## Talk to each model

Send a prompt to the deep model.

```sh
tetrix-host chat "What is 2 + 2? Answer with one number."
```

The model's reasoning appears dimmed, then its answer. Now send one to the quick model.

```sh
tetrix-host chat --quick "Say hello in five words."
```

The answer comes back faster. Notice that we asked for a kind of work both times, never for a model by name. Apps do the same.

## Look at the tunnel

An app on another device reaches the host through a relay. The host dialed out to the relay when it started, so your router needs no changes.

```sh
tetrix-host status
```

The status shows the tunnel connected.

```
Tunnel      connected to wss://relay.tetrix.tech
Deep work   ollama/qwen3:0.6b
Quick work  ollama/gemma3:270m
```

The relay passes sealed messages and holds no key that opens them. If you would rather not use Tetrix's, [run your own](../how-to/run-your-own-relay.md).

## Check the whole path

Last, we ask the host to check itself.

```sh
tetrix-host doctor
```

The final check pairs a throwaway device through the relay, sends one sealed request the way an app would, and unpairs the device.

```
  ok    The host is running at 127.0.0.1:4784.
  ok    The ollama engine answers and has 2 models.
  ok    Deep work uses ollama/qwen3:0.6b.
  ok    Quick work uses ollama/gemma3:270m.
  ok    A model answered a test request in 310ms.
  ok    The tunnel is connected to wss://relay.tetrix.tech.
  ok    A test device paired, sent a sealed request through the relay, and got an answer in 1.1s.

Everything works.
```

We now have a host that serves two models and that a paired device can reach.

## Where to go next

- [Pair an app](../how-to/pair-an-app.md) with the host.
- [Choose models](../how-to/choose-models.md) that suit your machine.
- [Run the host in the background](../how-to/run-in-the-background.md) so that it starts when you log in.
- Read [How Tetrix Host works](../explanation/how-it-works.md) for the reasons behind what you just did.
