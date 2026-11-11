package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
)

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

func cmdChat(args []string) error {
	fs := flag.NewFlagSet("chat", flag.ContinueOnError)
	quick := fs.Bool("quick", false, "use the model for quick work")
	model := fs.String("model", "", "use this model instead of a role")
	if err := fs.Parse(args); err != nil {
		return err
	}
	a, err := connect()
	if err != nil {
		return err
	}
	target := config.RoleDeep
	if *quick {
		target = config.RoleQuick
	}
	if *model != "" {
		target = *model
	}
	ctx, cancel := signalContext()
	defer cancel()

	var history []chatMessage
	ask := func(text string) error {
		history = append(history, chatMessage{Role: "user", Content: text})
		answer, err := streamChat(ctx, a, target, history)
		fmt.Println()
		if err != nil {
			history = history[:len(history)-1]
			return err
		}
		history = append(history, chatMessage{Role: "assistant", Content: answer})
		return nil
	}

	if fs.NArg() > 0 {
		return ask(strings.Join(fs.Args(), " "))
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		// Piped input is one prompt.
		data, err := bufio.NewReader(os.Stdin).ReadString(0)
		if err != nil && data == "" {
			return errors.New("nothing to send")
		}
		return ask(strings.TrimSpace(data))
	}
	fmt.Printf("Talking to the %s model. Press Ctrl-D to leave.\n\n", target)
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 64<<10), 1<<20)
	for {
		fmt.Print("> ")
		if !in.Scan() {
			fmt.Println()
			return nil
		}
		text := strings.TrimSpace(in.Text())
		if text == "" {
			continue
		}
		if err := ask(text); err != nil {
			if ctx.Err() != nil {
				return nil
			}
			fmt.Fprintln(os.Stderr, brand.CLI+": "+err.Error())
		}
		fmt.Println()
	}
}

// streamChat prints an answer as it arrives and returns the whole of it.
func streamChat(ctx context.Context, a *admin, model string, messages []chatMessage) (string, error) {
	resp, err := a.request(ctx, "POST", "/v1/chat/completions", map[string]any{
		"model": model, "messages": messages, "stream": true,
	})
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var answer strings.Builder
	thinking := false
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64<<10), 4<<20)
	for scanner.Scan() {
		data, ok := strings.CutPrefix(scanner.Text(), "data: ")
		if !ok || data == "[DONE]" {
			continue
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content   string `json:"content"`
					Reasoning string `json:"reasoning"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(data), &chunk) != nil || len(chunk.Choices) == 0 {
			continue
		}
		delta := chunk.Choices[0].Delta
		// Show a model's reasoning dimmed, so the answer stands apart.
		if delta.Reasoning != "" {
			if !thinking {
				thinking = true
				fmt.Print("\x1b[2m")
			}
			fmt.Print(delta.Reasoning)
		}
		if delta.Content != "" {
			if thinking {
				thinking = false
				fmt.Print("\x1b[0m\n")
			}
			fmt.Print(delta.Content)
			answer.WriteString(delta.Content)
		}
	}
	if thinking {
		fmt.Print("\x1b[0m")
	}
	if err := scanner.Err(); err != nil && ctx.Err() == nil {
		return answer.String(), err
	}
	return answer.String(), nil
}
