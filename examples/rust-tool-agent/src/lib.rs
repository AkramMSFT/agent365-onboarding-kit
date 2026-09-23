use serde_json::{json, Value};
use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

const MAX_RESPONSE_BYTES: u64 = 2 * 1024 * 1024;

pub trait Model {
    fn complete(&mut self, messages: &[Value]) -> Result<Value, String>;
}

pub fn tools() -> Value {
    Value::Array(["count_words", "reverse_text"].iter().map(|name| json!({
        "type": "function",
        "function": {
            "name": name,
            "description": if *name == "count_words" { "Count whitespace-separated words." } else { "Reverse Unicode code points." },
            "parameters": {
                "type": "object", "properties": {"text": {"type": "string", "maxLength": 100000}},
                "required": ["text"], "additionalProperties": false
            }
        }
    })).collect())
}

pub fn invoke_tool(name: &str, arguments: &str) -> Value {
    let input: Value = match serde_json::from_str(arguments) {
        Ok(value) => value,
        Err(_) => return json!({"error": "invalid tool arguments"}),
    };
    let object = match input.as_object() {
        Some(value) if value.len() == 1 => value,
        _ => return json!({"error": "invalid tool arguments; expected text"}),
    };
    let text = match object.get("text").and_then(Value::as_str) {
        Some(value) => value,
        None => return json!({"error": "invalid tool arguments; expected text"}),
    };
    if text.len() > 100000 {
        return json!({"error": "tool text exceeds 100000 UTF-8 bytes"});
    }
    match name {
        "count_words" => json!({"words": text.split_whitespace().count()}),
        "reverse_text" => json!({"text": text.chars().rev().collect::<String>()}),
        _ => json!({"error": "unknown tool"}),
    }
}

pub fn run_agent(model: &mut dyn Model, prompt: &str, max_turns: usize) -> Result<String, String> {
    if prompt.chars().count() > 4000 {
        return Err("prompt exceeds 4000 characters".into());
    }
    let mut messages = vec![
        json!({"role": "system", "content": "Use count_words for exact word counts and reverse_text to reverse text. Do not invent tool results."}),
        json!({"role": "user", "content": prompt}),
    ];
    for _ in 0..max_turns {
        let reply = model.complete(&messages)?;
        if reply.get("role").and_then(Value::as_str) != Some("assistant") {
            return Err("model returned a non-assistant message".into());
        }
        let calls = match reply.get("tool_calls") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(values)) => values.clone(),
            _ => return Err("invalid tool call shape".into()),
        };
        if calls.is_empty() {
            return reply
                .get("content")
                .and_then(Value::as_str)
                .filter(|text| !text.trim().is_empty())
                .map(str::to_owned)
                .ok_or_else(|| "model returned no text or tool calls".into());
        }
        if calls.len() > 16 {
            return Err("model returned too many tool calls".into());
        }
        messages.push(reply);
        for call in calls {
            let id = call
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .ok_or("missing tool call ID")?;
            if call.get("type").and_then(Value::as_str) != Some("function") {
                return Err("invalid tool call type".into());
            }
            let function = call.get("function").ok_or("missing function")?;
            let name = function
                .get("name")
                .and_then(Value::as_str)
                .ok_or("missing function name")?;
            let arguments = function
                .get("arguments")
                .and_then(Value::as_str)
                .ok_or("missing function arguments")?;
            messages.push(json!({"role": "tool", "tool_call_id": id, "content": invoke_tool(name, arguments).to_string()}));
        }
    }
    Err("model/tool turn limit reached".into())
}

pub struct OfflineModel {
    pub text: String,
    pub requests: usize,
}
impl OfflineModel {
    pub fn new(text: &str) -> Self {
        Self {
            text: text.into(),
            requests: 0,
        }
    }
}
impl Model for OfflineModel {
    fn complete(&mut self, messages: &[Value]) -> Result<Value, String> {
        self.requests += 1;
        if self.requests == 1 {
            return Ok(json!({"role": "assistant", "tool_calls": [{
                "id": "offline-count", "type": "function",
                "function": {"name": "count_words", "arguments": json!({"text": self.text}).to_string()}
            }]}));
        }
        let last = messages.last().ok_or("missing offline result")?;
        if self.requests != 2
            || last.get("tool_call_id").and_then(Value::as_str) != Some("offline-count")
        {
            return Err("unexpected offline tool loop".into());
        }
        let content = last
            .get("content")
            .and_then(Value::as_str)
            .ok_or("missing tool result")?;
        let value: Value = serde_json::from_str(content).map_err(|_| "invalid offline result")?;
        let words = value
            .get("words")
            .and_then(Value::as_u64)
            .ok_or("missing word count")?;
        Ok(json!({"role": "assistant", "content": format!("Word count: {words}")}))
    }
}

pub struct Provider {
    pub model: String,
    key: String,
    endpoint: String,
}
impl Provider {
    pub fn from_environment(get: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        let provider = get("MODEL_PROVIDER")
            .unwrap_or_else(|| "mistral".into())
            .trim()
            .to_lowercase();
        let (prefix, default_model, endpoint) = match provider.as_str() {
            "mistral" => (
                "MISTRAL",
                "ministral-3b-2512",
                "https://api.mistral.ai/v1/chat/completions",
            ),
            "openai" => (
                "OPENAI",
                "gpt-4.1-mini",
                "https://api.openai.com/v1/chat/completions",
            ),
            "gemini" => (
                "GEMINI",
                "gemini-2.5-flash-lite",
                "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            ),
            _ => return Err("MODEL_PROVIDER must be mistral, openai or gemini".into()),
        };
        let key = get(&format!("{prefix}_API_KEY"))
            .unwrap_or_default()
            .trim()
            .to_owned();
        if key.is_empty() || key.chars().any(char::is_control) {
            return Err(format!("set a valid {prefix}_API_KEY for live mode"));
        }
        let model = get(&format!("{prefix}_MODEL"))
            .unwrap_or_default()
            .trim()
            .to_owned();
        Ok(Self {
            model: if model.is_empty() {
                default_model.into()
            } else {
                model
            },
            key,
            endpoint: endpoint.into(),
        })
    }
}

pub struct HttpModel {
    provider: Provider,
    client: ureq::Agent,
}
impl HttpModel {
    pub fn new(provider: Provider) -> Result<Self, String> {
        let tls = native_tls::TlsConnector::new().map_err(|_| "could not initialize TLS")?;
        let client = ureq::AgentBuilder::new()
            .tls_connector(Arc::new(tls))
            .timeout(Duration::from_secs(15))
            .redirects(0)
            .build();
        Ok(Self { provider, client })
    }
}
impl Model for HttpModel {
    fn complete(&mut self, messages: &[Value]) -> Result<Value, String> {
        let response = self
            .client
            .post(&self.provider.endpoint)
            .set("Authorization", &format!("Bearer {}", self.provider.key))
            .send_json(
                json!({"model": self.provider.model, "messages": messages, "tools": tools()}),
            );
        let response = match response {
            Ok(response) => response,
            Err(ureq::Error::Status(status, _)) => {
                return Err(format!("model request failed: HTTP {status}"))
            }
            Err(ureq::Error::Transport(_)) => {
                return Err("model transport failed; check network/TLS".into())
            }
        };
        if !(200..300).contains(&response.status()) {
            return Err(format!("model request failed: HTTP {}", response.status()));
        }
        let mut bytes = Vec::new();
        response
            .into_reader()
            .take(MAX_RESPONSE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "could not read model response")?;
        if bytes.len() as u64 > MAX_RESPONSE_BYTES {
            return Err("model response exceeds 2 MiB".into());
        }
        let value: Value =
            serde_json::from_slice(&bytes).map_err(|_| "invalid model JSON response")?;
        value
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first())
            .and_then(|choice| choice.get("message"))
            .filter(|message| message.is_object())
            .cloned()
            .ok_or_else(|| "invalid chat-completions response".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::thread;
    use std::time::Instant;

    #[test]
    fn word_count() {
        assert_eq!(
            invoke_tool("count_words", r#"{"text":"Hello  世界\u3000Agent\n365"}"#),
            json!({"words":4})
        );
        assert_eq!(
            invoke_tool("count_words", r#"{"text":""}"#),
            json!({"words":0})
        );
        assert_eq!(
            invoke_tool("reverse_text", r#"{"text":"A😀B"}"#),
            json!({"text":"B😀A"})
        );
        assert!(invoke_tool("unknown", r#"{"text":"x"}"#)
            .get("error")
            .is_some());
        assert!(invoke_tool("count_words", "{}").get("error").is_some());
    }
    #[test]
    fn offline_agent() {
        let mut model = OfflineModel::new("Hello Agent 365");
        assert_eq!(
            run_agent(&mut model, "Hello Agent 365", 6).unwrap(),
            "Word count: 3"
        );
        assert_eq!(model.requests, 2);
        assert!(run_agent(&mut OfflineModel::new("x"), "x", 1).is_err());
    }
    #[test]
    fn provider_isolation() {
        assert!(Provider::from_environment(|key| match key {
            "MODEL_PROVIDER" => Some("openai".into()),
            "MISTRAL_API_KEY" => Some("not-reused".into()),
            _ => None,
        })
        .is_err());
    }
    #[test]
    fn http_tool_loop() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let server = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(15);
            for index in 0..2 {
                let (mut stream, _) = loop {
                    match listener.accept() {
                        Ok(connection) => break connection,
                        Err(error)
                            if error.kind() == std::io::ErrorKind::WouldBlock
                                && Instant::now() < deadline =>
                        {
                            thread::sleep(Duration::from_millis(5))
                        }
                        Err(error) => panic!("loopback server failed: {error}"),
                    }
                };
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut length = 0;
                let mut auth = false;
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    if line == "\r\n" {
                        break;
                    }
                    if let Some(value) = line.to_lowercase().strip_prefix("content-length:") {
                        length = value.trim().parse::<usize>().unwrap();
                    }
                    if line
                        .trim()
                        .eq_ignore_ascii_case("authorization: Bearer offline-key")
                    {
                        auth = true;
                    }
                }
                assert!(auth);
                let mut body = vec![0; length];
                reader.read_exact(&mut body).unwrap();
                let request: Value = serde_json::from_slice(&body).unwrap();
                assert_eq!(request["tools"].as_array().unwrap().len(), 2);
                let message = if index == 0 {
                    json!({"role":"assistant","tool_calls":[{"id":"http-count","type":"function","function":{
                        "name":"count_words","arguments":"{\"text\":\"Hello Agent 365\"}"}}]})
                } else {
                    assert_eq!(
                        request["messages"].as_array().unwrap().last().unwrap()["content"],
                        "{\"words\":3}"
                    );
                    json!({"role":"assistant","content":"Word count: 3"})
                };
                let reply = json!({"choices":[{"message":message}]}).to_string();
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", reply.len(), reply).unwrap();
            }
        });
        let mut model = HttpModel::new(Provider {
            model: "offline".into(),
            key: "offline-key".into(),
            endpoint,
        })
        .unwrap();
        assert_eq!(
            run_agent(&mut model, "Count words", 6).unwrap(),
            "Word count: 3"
        );
        server.join().unwrap();
    }
}
