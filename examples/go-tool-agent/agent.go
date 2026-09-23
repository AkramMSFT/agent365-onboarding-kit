package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode"
)

const maxResponseBytes = 2 * 1024 * 1024
const instructions = "Use count_words for exact whitespace-separated word counts and reverse_text to reverse Unicode code points. Do not invent tool results."

type Message map[string]any
type Model interface {
	Complete(context.Context, []Message) (Message, error)
}
type ToolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

func toolDefinitions() []any {
	result := make([]any, 0, 2)
	for _, name := range []string{"count_words", "reverse_text"} {
		result = append(result, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": name, "description": map[string]string{
					"count_words":  "Count whitespace-separated words in text.",
					"reverse_text": "Reverse Unicode code points in text.",
				}[name],
				"parameters": map[string]any{"type": "object", "properties": map[string]any{
					"text": map[string]any{"type": "string", "maxLength": 100000}},
					"required": []string{"text"}, "additionalProperties": false},
			},
		})
	}
	return result
}

func invokeTool(name, arguments string) string {
	encode := func(value any) string { data, _ := json.Marshal(value); return string(data) }
	var input struct {
		Text *string `json:"text"`
	}
	decoder := json.NewDecoder(strings.NewReader(arguments))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.Text == nil {
		return encode(map[string]string{"error": "invalid tool arguments; expected text"})
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return encode(map[string]string{"error": "trailing tool argument data"})
	}
	if len(*input.Text) > 100000 {
		return encode(map[string]string{"error": "tool text exceeds 100000 UTF-8 bytes"})
	}
	switch name {
	case "count_words":
		return encode(map[string]int{"words": len(strings.Fields(*input.Text))})
	case "reverse_text":
		runes := []rune(*input.Text)
		for left, right := 0, len(runes)-1; left < right; left, right = left+1, right-1 {
			runes[left], runes[right] = runes[right], runes[left]
		}
		return encode(map[string]string{"text": string(runes)})
	default:
		return encode(map[string]string{"error": "unknown tool"})
	}
}

func runAgent(ctx context.Context, model Model, prompt string, maxTurns int) (string, error) {
	if len([]rune(prompt)) > 4000 {
		return "", errors.New("prompt exceeds 4000 characters")
	}
	messages := []Message{{"role": "system", "content": instructions}, {"role": "user", "content": prompt}}
	for turn := 0; turn < maxTurns; turn++ {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		reply, err := model.Complete(ctx, messages)
		if err != nil {
			return "", err
		}
		if reply["role"] != "assistant" {
			return "", errors.New("model returned a non-assistant message")
		}
		var calls []ToolCall
		if raw, exists := reply["tool_calls"]; exists {
			data, err := json.Marshal(raw)
			if err != nil {
				return "", errors.New("invalid tool call payload")
			}
			if err = json.Unmarshal(data, &calls); err != nil {
				return "", errors.New("invalid tool call shape")
			}
		}
		if len(calls) == 0 {
			text, ok := reply["content"].(string)
			if !ok || strings.TrimSpace(text) == "" {
				return "", errors.New("model returned no text or tool calls")
			}
			return text, nil
		}
		if len(calls) > 16 {
			return "", errors.New("model returned too many tool calls")
		}
		messages = append(messages, reply)
		for _, call := range calls {
			if call.ID == "" || call.Type != "function" {
				return "", errors.New("invalid function-call metadata")
			}
			messages = append(messages, Message{"role": "tool", "tool_call_id": call.ID,
				"content": invokeTool(call.Function.Name, call.Function.Arguments)})
		}
	}
	return "", errors.New("model/tool turn limit reached")
}

type OfflineModel struct {
	Text     string
	Requests int
}

func (m *OfflineModel) Complete(_ context.Context, messages []Message) (Message, error) {
	m.Requests++
	if m.Requests == 1 {
		arguments, _ := json.Marshal(map[string]string{"text": m.Text})
		return Message{"role": "assistant", "tool_calls": []any{map[string]any{
			"id": "offline-count", "type": "function",
			"function": map[string]string{"name": "count_words", "arguments": string(arguments)}}}}, nil
	}
	last := messages[len(messages)-1]
	if m.Requests != 2 || last["role"] != "tool" || last["tool_call_id"] != "offline-count" {
		return nil, errors.New("unexpected offline tool loop")
	}
	var value struct {
		Words int `json:"words"`
	}
	content, ok := last["content"].(string)
	if !ok || json.Unmarshal([]byte(content), &value) != nil {
		return nil, errors.New("invalid offline tool result")
	}
	return Message{"role": "assistant", "content": fmt.Sprintf("Word count: %d", value.Words)}, nil
}

type HTTPModel struct {
	Endpoint, Key, Name string
	Client              *http.Client
}

func providerFromEnv(getenv func(string) string) (*HTTPModel, error) {
	provider := strings.ToLower(strings.TrimSpace(getenv("MODEL_PROVIDER")))
	if provider == "" {
		provider = "mistral"
	}
	settings := map[string][3]string{
		"mistral": {"MISTRAL", "ministral-3b-2512", "https://api.mistral.ai/v1/chat/completions"},
		"openai":  {"OPENAI", "gpt-4.1-mini", "https://api.openai.com/v1/chat/completions"},
		"gemini":  {"GEMINI", "gemini-2.5-flash-lite", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"},
	}
	selected, ok := settings[provider]
	if !ok {
		return nil, errors.New("MODEL_PROVIDER must be mistral, openai or gemini")
	}
	key := strings.TrimSpace(getenv(selected[0] + "_API_KEY"))
	if key == "" || strings.IndexFunc(key, unicode.IsControl) >= 0 {
		return nil, fmt.Errorf("set %s_API_KEY for live mode", selected[0])
	}
	name := strings.TrimSpace(getenv(selected[0] + "_MODEL"))
	if name == "" {
		name = selected[1]
	}
	return &HTTPModel{Endpoint: selected[2], Key: key, Name: name, Client: &http.Client{
		Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (m *HTTPModel) Complete(ctx context.Context, messages []Message) (Message, error) {
	data, err := json.Marshal(map[string]any{"model": m.Name, "messages": messages, "tools": toolDefinitions()})
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, m.Endpoint, bytes.NewReader(data))
	if err != nil {
		return nil, errors.New("invalid model endpoint")
	}
	request.Header.Set("Authorization", "Bearer "+m.Key)
	request.Header.Set("Content-Type", "application/json")
	response, err := m.Client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("model transport failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("model request failed: HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil {
		return nil, errors.New("could not read model response")
	}
	if len(body) > maxResponseBytes {
		return nil, errors.New("model response exceeds 2 MiB")
	}
	var result struct {
		Choices []struct {
			Message Message `json:"message"`
		} `json:"choices"`
	}
	if json.Unmarshal(body, &result) != nil || len(result.Choices) == 0 {
		return nil, errors.New("invalid chat-completions response")
	}
	return result.Choices[0].Message, nil
}
