package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestWordCount(t *testing.T) {
	if got := invokeTool("count_words", `{"text":"Hello  世界\u3000Agent\n365"}`); got != `{"words":4}` {
		t.Fatal(got)
	}
	if got := invokeTool("count_words", `{"text":""}`); got != `{"words":0}` {
		t.Fatal(got)
	}
	if !strings.Contains(invokeTool("count_words", `{}`), "error") {
		t.Fatal("missing text accepted")
	}
	if !strings.Contains(invokeTool("unknown", `{"text":"x"}`), "unknown tool") {
		t.Fatal("unknown tool accepted")
	}
	if got := invokeTool("reverse_text", `{"text":"A😀B"}`); got != `{"text":"B😀A"}` {
		t.Fatal(got)
	}
}

func TestOfflineAgent(t *testing.T) {
	model := &OfflineModel{Text: "Hello Agent 365"}
	output, err := runAgent(context.Background(), model, model.Text, 6)
	if err != nil || output != "Word count: 3" || model.Requests != 2 {
		t.Fatalf("%q %v", output, err)
	}
	_, err = runAgent(context.Background(), &OfflineModel{Text: "x"}, "x", 1)
	if err == nil {
		t.Fatal("turn limit was ignored")
	}
}

func TestHTTPToolLoop(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer offline-key" {
			t.Error("wrong auth header")
		}
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil {
			t.Fatal("invalid request")
		}
		if body["model"] != "offline-model" || len(body["tools"].([]any)) != 2 {
			t.Error("lost model/tools")
		}
		w.Header().Set("Content-Type", "application/json")
		if calls == 1 {
			_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"http-count","type":"function","function":{"name":"count_words","arguments":"{\"text\":\"Hello Agent 365\"}"}}]}}]}`))
		} else {
			messages := body["messages"].([]any)
			result := messages[len(messages)-1].(map[string]any)
			if result["tool_call_id"] != "http-count" || result["content"] != `{"words":3}` {
				t.Error("lost tool result")
			}
			_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"Word count: 3"}}]}`))
		}
	}))
	defer server.Close()
	model := &HTTPModel{Endpoint: server.URL, Key: "offline-key", Name: "offline-model", Client: server.Client()}
	output, err := runAgent(context.Background(), model, "Count three words", 6)
	if err != nil || output != "Word count: 3" || calls != 2 {
		t.Fatalf("%q %v", output, err)
	}
}

func TestProviderIsolationAndHTTPFailure(t *testing.T) {
	values := map[string]string{"MODEL_PROVIDER": "openai", "MISTRAL_API_KEY": "must-not-be-reused"}
	if _, err := providerFromEnv(func(k string) string { return values[k] }); err == nil {
		t.Fatal("cross-provider key reuse")
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(403) }))
	defer server.Close()
	_, err := (&HTTPModel{Endpoint: server.URL, Key: "offline-key", Client: server.Client()}).Complete(context.Background(), nil)
	if err == nil || !strings.Contains(err.Error(), "HTTP 403") || strings.Contains(err.Error(), "offline-key") {
		t.Fatal(err)
	}
}

func TestResponseLimit(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(strings.Repeat("x", maxResponseBytes+1)))
	}))
	defer server.Close()
	_, err := (&HTTPModel{Endpoint: server.URL, Key: "offline-key", Client: server.Client()}).Complete(context.Background(), nil)
	if err == nil || !strings.Contains(err.Error(), "2 MiB") {
		t.Fatal(err)
	}
}
