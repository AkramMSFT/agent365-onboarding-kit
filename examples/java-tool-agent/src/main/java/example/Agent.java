package example;

import com.google.gson.*;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.URI;
import java.net.http.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.Pattern;

public final class Agent {
    static final int MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
    static final Gson JSON = new Gson();
    interface Model extends AutoCloseable {
        JsonObject complete(JsonArray messages) throws Exception;
        default void close() {}
    }
    static JsonObject object(Object value) { return JSON.toJsonTree(value).getAsJsonObject(); }
    static JsonArray tools() {
        var result = new JsonArray();
        for (String name : List.of("count_words", "reverse_text")) {
            result.add(object(Map.of("type", "function", "function", Map.of(
                "name", name, "description", name.equals("count_words") ? "Count whitespace-separated words." : "Reverse Unicode code points.",
                "parameters", Map.of("type", "object", "properties", Map.of("text", Map.of("type", "string", "maxLength", 100000)),
                    "required", List.of("text"), "additionalProperties", false)))));
        }
        return result;
    }
    static String invoke(String name, String arguments) {
        try {
            var input = JsonParser.parseString(arguments).getAsJsonObject();
            var value = input.get("text");
            if (input.size() != 1 || value == null || !value.isJsonPrimitive() || !value.getAsJsonPrimitive().isString())
                return "{\"error\":\"invalid tool arguments; expected text\"}";
            String text = value.getAsString();
            if (text.getBytes(StandardCharsets.UTF_8).length > 100000) return "{\"error\":\"tool text exceeds 100000 UTF-8 bytes\"}";
            return switch (name) {
                case "count_words" -> JSON.toJson(Map.of("words", Pattern.compile("\\S+", Pattern.UNICODE_CHARACTER_CLASS).matcher(text).results().count()));
                case "reverse_text" -> JSON.toJson(Map.of("text", new StringBuilder(text).reverse().toString()));
                default -> "{\"error\":\"unknown tool\"}";
            };
        } catch (JsonParseException | IllegalStateException exception) {
            return "{\"error\":\"invalid tool arguments\"}";
        }
    }
    static String run(Model model, String prompt, int limit) throws Exception {
        if (prompt.codePointCount(0, prompt.length()) > 4000) throw new IllegalArgumentException("Prompt exceeds 4000 characters.");
        var messages = new JsonArray();
        messages.add(object(Map.of("role", "system", "content", "Use count_words for exact word counts and reverse_text to reverse text. Do not invent tool results.")));
        messages.add(object(Map.of("role", "user", "content", prompt)));
        for (int turn = 0; turn < limit; turn++) {
            var reply = model.complete(messages);
            if (reply == null || !reply.has("role") || !"assistant".equals(reply.get("role").getAsString()))
                throw new IOException("Model returned a non-assistant message.");
            var calls = reply.has("tool_calls") && !reply.get("tool_calls").isJsonNull() ? reply.getAsJsonArray("tool_calls") : new JsonArray();
            if (calls.isEmpty()) {
                var content = reply.get("content");
                if (content == null || !content.isJsonPrimitive() || !content.getAsJsonPrimitive().isString() || content.getAsString().isBlank())
                    throw new IOException("Model returned no text or tool calls.");
                return content.getAsString();
            }
            if (calls.size() > 16) throw new IOException("Model returned too many tool calls.");
            messages.add(reply.deepCopy());
            for (var element : calls) {
                var call = element.getAsJsonObject();
                if (!call.has("id") || call.get("id").getAsString().isBlank() || !"function".equals(call.get("type").getAsString()))
                    throw new IOException("Invalid function-call metadata.");
                var function = call.getAsJsonObject("function");
                messages.add(object(Map.of("role", "tool", "tool_call_id", call.get("id").getAsString(),
                    "content", invoke(function.get("name").getAsString(), function.get("arguments").getAsString()))));
            }
        }
        throw new IOException("Model/tool turn limit reached.");
    }
    static final class OfflineModel implements Model {
        final String text; int requests;
        OfflineModel(String text) { this.text = text; }
        public JsonObject complete(JsonArray messages) throws IOException {
            requests++;
            if (requests == 1) return object(Map.of("role", "assistant", "tool_calls", List.of(Map.of(
                "id", "offline-count", "type", "function", "function", Map.of("name", "count_words", "arguments", JSON.toJson(Map.of("text", text)))))));
            var last = messages.get(messages.size() - 1).getAsJsonObject();
            if (requests != 2 || !"offline-count".equals(last.get("tool_call_id").getAsString())) throw new IOException("Unexpected offline tool loop.");
            int words = JsonParser.parseString(last.get("content").getAsString()).getAsJsonObject().get("words").getAsInt();
            return object(Map.of("role", "assistant", "content", "Word count: " + words));
        }
    }
    record Provider(String provider, String model, String key, URI endpoint) {
        static Provider from(Map<String, String> environment) {
            String provider = environment.getOrDefault("MODEL_PROVIDER", "mistral").strip().toLowerCase(Locale.ROOT);
            String[] selected = switch (provider) {
                case "mistral" -> new String[]{"MISTRAL", "ministral-3b-2512", "https://api.mistral.ai/v1/chat/completions"};
                case "openai" -> new String[]{"OPENAI", "gpt-4.1-mini", "https://api.openai.com/v1/chat/completions"};
                case "gemini" -> new String[]{"GEMINI", "gemini-2.5-flash-lite", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"};
                default -> throw new IllegalArgumentException("MODEL_PROVIDER must be mistral, openai or gemini.");
            };
            String key = environment.getOrDefault(selected[0] + "_API_KEY", "").strip();
            if (key.isEmpty() || key.codePoints().anyMatch(Character::isISOControl)) throw new IllegalArgumentException("Set a valid " + selected[0] + "_API_KEY.");
            String model = environment.getOrDefault(selected[0] + "_MODEL", "").strip();
            return new Provider(provider, model.isEmpty() ? selected[1] : model, key, URI.create(selected[2]));
        }
        public String toString() { return provider + ":" + model; }
    }
    static final class HttpModel implements Model {
        final Provider provider;
        final HttpClient client = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).connectTimeout(Duration.ofSeconds(10)).build();
        HttpModel(Provider provider) { this.provider = provider; }
        public JsonObject complete(JsonArray messages) throws Exception {
            var body = object(Map.of("model", provider.model(), "messages", messages, "tools", tools()));
            var request = HttpRequest.newBuilder(provider.endpoint()).timeout(Duration.ofSeconds(15))
                .header("Authorization", "Bearer " + provider.key()).header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(JSON.toJson(body))).build();
            var future = client.sendAsync(request, info -> new LimitedBody());
            HttpResponse<byte[]> response;
            try { response = future.get(15, TimeUnit.SECONDS); }
            catch (TimeoutException exception) { future.cancel(true); throw new IOException("Model request timed out."); }
            catch (ExecutionException exception) { throw new IOException("Model transport or bounded response read failed."); }
            if (response.statusCode() < 200 || response.statusCode() >= 300) throw new IOException("Model request failed: HTTP " + response.statusCode());
            var result = JsonParser.parseString(new String(response.body(), StandardCharsets.UTF_8)).getAsJsonObject();
            if (!result.has("choices") || result.getAsJsonArray("choices").isEmpty()) throw new IOException("Invalid chat-completions response.");
            return result.getAsJsonArray("choices").get(0).getAsJsonObject().getAsJsonObject("message");
        }
        public void close() { client.close(); }
    }
    static final class LimitedBody implements HttpResponse.BodySubscriber<byte[]> {
        private final CompletableFuture<byte[]> body = new CompletableFuture<>();
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        private Flow.Subscription subscription;
        public CompletionStage<byte[]> getBody() { return body; }
        public void onSubscribe(Flow.Subscription value) { subscription = value; value.request(1); }
        public void onNext(List<ByteBuffer> buffers) {
            for (var buffer : buffers) {
                if (buffer.remaining() > MAX_RESPONSE_BYTES - bytes.size()) {
                    subscription.cancel(); body.completeExceptionally(new IOException("Model response exceeds 2 MiB.")); return;
                }
                byte[] data = new byte[buffer.remaining()]; buffer.get(data); bytes.writeBytes(data);
            }
            subscription.request(1);
        }
        public void onError(Throwable error) { body.completeExceptionally(error); }
        public void onComplete() { body.complete(bytes.toByteArray()); }
    }
}
