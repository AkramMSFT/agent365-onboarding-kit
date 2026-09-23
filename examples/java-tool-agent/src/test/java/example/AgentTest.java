package example;

import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AgentTest {
    @Test void wordCount() {
        assertEquals("{\"words\":4}", Agent.invoke("count_words", "{\"text\":\"Hello  世界\\u3000Agent\\n365\"}"));
        assertEquals("{\"words\":0}", Agent.invoke("count_words", "{\"text\":\"\"}"));
        assertEquals("{\"text\":\"B😀A\"}", Agent.invoke("reverse_text", "{\"text\":\"A😀B\"}"));
        assertTrue(Agent.invoke("count_words", "{}").contains("error"));
        assertTrue(Agent.invoke("unknown", "{\"text\":\"x\"}").contains("unknown tool"));
    }
    @Test void offlineAgent() throws Exception {
        var model = new Agent.OfflineModel("Hello Agent 365");
        assertEquals("Word count: 3", Agent.run(model, model.text, 6));
        assertEquals(2, model.requests);
        assertThrows(Exception.class, () -> Agent.run(new Agent.OfflineModel("x"), "x", 1));
    }
    @Test void providerIsolation() {
        assertThrows(IllegalArgumentException.class, () -> Agent.Provider.from(Map.of("MODEL_PROVIDER", "openai", "MISTRAL_API_KEY", "wrong-provider")));
        var provider = Agent.Provider.from(Map.of("MODEL_PROVIDER", "gemini", "GEMINI_API_KEY", "offline-key"));
        assertEquals("generativelanguage.googleapis.com", provider.endpoint().getHost());
        assertFalse(provider.toString().contains("offline-key"));
    }
    @Test void httpToolLoop() throws Exception {
        var calls = new AtomicInteger();
        var server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        server.createContext("/chat", exchange -> {
            var request = JsonParser.parseString(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8)).getAsJsonObject();
            assertEquals("Bearer offline-key", exchange.getRequestHeaders().getFirst("Authorization"));
            assertEquals(2, request.getAsJsonArray("tools").size());
            JsonObject message;
            if (calls.incrementAndGet() == 1) message = Agent.object(Map.of("role", "assistant", "tool_calls", java.util.List.of(Map.of(
                "id", "http-count", "type", "function", "function", Map.of("name", "count_words", "arguments", "{\"text\":\"Hello Agent 365\"}")))));
            else {
                var messages = request.getAsJsonArray("messages");
                assertEquals("{\"words\":3}", messages.get(messages.size()-1).getAsJsonObject().get("content").getAsString());
                message = Agent.object(Map.of("role", "assistant", "content", "Word count: 3"));
            }
            byte[] bytes = Agent.JSON.toJson(Map.of("choices", java.util.List.of(Map.of("message", message)))).getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, bytes.length);
            try (var body = exchange.getResponseBody()) { body.write(bytes); }
        });
        server.start();
        try (var model = new Agent.HttpModel(new Agent.Provider("fixture", "offline-model", "offline-key",
            URI.create("http://localhost:" + server.getAddress().getPort() + "/chat")))) {
            assertEquals("Word count: 3", Agent.run(model, "Count words", 6));
            assertEquals(2, calls.get());
        } finally { server.stop(0); }
    }
    @Test void responseLimit() {
        var body = new Agent.LimitedBody();
        var canceled = new java.util.concurrent.atomic.AtomicBoolean();
        body.onSubscribe(new java.util.concurrent.Flow.Subscription() {
            public void request(long count) {}
            public void cancel() { canceled.set(true); }
        });
        body.onNext(java.util.List.of(java.nio.ByteBuffer.allocate(Agent.MAX_RESPONSE_BYTES + 1)));
        assertTrue(canceled.get());
        assertTrue(body.getBody().toCompletableFuture().isCompletedExceptionally());
    }
}
