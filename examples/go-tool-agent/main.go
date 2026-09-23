package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "--help" {
		fmt.Println("go run . [--mock|--live] [text/prompt]\nDefault is a deterministic offline model/tool loop. Live mode requires MODEL_PROVIDER and its provider-specific API key.")
		return
	}
	mode := "--mock"
	if len(args) > 0 && strings.HasPrefix(args[0], "--") {
		mode, args = args[0], args[1:]
	}
	if mode != "--mock" && mode != "--live" {
		fmt.Fprintln(os.Stderr, "Use --mock or --live.")
		os.Exit(1)
	}
	prompt := "Hello Agent 365"
	if len(args) > 0 {
		prompt = strings.Join(args, " ")
	}
	var model Model
	offline := &OfflineModel{Text: prompt}
	if mode == "--live" {
		var err error
		model, err = providerFromEnv(os.Getenv)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	} else {
		model = offline
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	output, err := runAgent(ctx, model, prompt, 6)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if mode == "--mock" {
		if err := json.NewEncoder(os.Stdout).Encode(map[string]any{
			"mode": "mock", "aiInference": false, "output": output, "modelRequests": offline.Requests,
		}); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	} else {
		fmt.Println(output)
	}
}
