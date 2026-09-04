# Java — Agent 365 hosting layer

Every code block here was compiled against **JDK 21** and run: `/api/health` returns 200,
an anonymous POST to `/api/messages` returns 401, a forged bearer returns 401, and a GET
returns 405. What has **not** been exercised against a tenant is a real inbound activity
from Teams and a real reply through the Connector API — those need a published agent.

Java 17 is the floor (`java.net.http.HttpClient`, records, `Map.of`).

## Dependencies

Maven:

```xml
<dependency>
  <groupId>com.fasterxml.jackson.core</groupId>
  <artifactId>jackson-databind</artifactId>
  <version>2.17.2</version>
</dependency>
<dependency>
  <groupId>com.nimbusds</groupId>
  <artifactId>nimbus-jose-jwt</artifactId>
  <version>9.40</version>
</dependency>
```

Gradle:

```groovy
implementation 'com.fasterxml.jackson.core:jackson-databind:2.17.2'
implementation 'com.nimbusds:nimbus-jose-jwt:9.40'
```

> Nimbus exposes `DefaultJWTProcessor`; there is no `ConfiguredJWTProcessor`. Declaring the
> field as the latter compiles in no version of 9.x.

## Environment

| Variable | Value |
|---|---|
| `AGENT365_TENANT_ID` | tenant GUID |
| `AGENT365_CLIENT_ID` | blueprint app id — also the expected inbound audience |
| `AGENT365_CLIENT_SECRET` | blueprint client secret |
| `AGENT365_AGENT_ID` | instance appId for telemetry; defaults to the client id |
| `PORT` | listen port, default 3978 |
| `ENABLE_A365_OBSERVABILITY_EXPORTER` | `true` to export |

## TokenProvider

Client-credentials tokens for the blueprint app, cached and refreshed five minutes early.

```java
package com.example.a365;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** Client-credentials tokens for the blueprint app, cached until shortly before expiry. */
public final class TokenProvider {

    private record Entry(String token, Instant expiresAt) {}

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10)).build();
    private final ObjectMapper mapper = new ObjectMapper();
    private final Map<String, Entry> cache = new ConcurrentHashMap<>();

    private final String tenantId;
    private final String clientId;
    private final String clientSecret;

    public TokenProvider(String tenantId, String clientId, String clientSecret) {
        this.tenantId = tenantId;
        this.clientId = clientId;
        this.clientSecret = clientSecret;
    }

    /** @param scope e.g. "https://api.botframework.com/.default" */
    public String getToken(String scope) throws Exception {
        Entry cached = cache.get(scope);
        if (cached != null && Instant.now().isBefore(cached.expiresAt())) {
            return cached.token();
        }
        String form = "grant_type=client_credentials"
                + "&client_id=" + enc(clientId)
                + "&client_secret=" + enc(clientSecret)
                + "&scope=" + enc(scope);

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create("https://login.microsoftonline.com/" + tenantId + "/oauth2/v2.0/token"))
                .header("content-type", "application/x-www-form-urlencoded")
                .timeout(Duration.ofSeconds(30))
                .POST(HttpRequest.BodyPublishers.ofString(form))
                .build();

        HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() / 100 != 2) {
            throw new IllegalStateException("Token request failed: HTTP " + response.statusCode()
                    + " " + response.body());
        }
        JsonNode body = mapper.readTree(response.body());
        String token = body.path("access_token").asText();
        long expiresIn = body.path("expires_in").asLong(3600);

        // Refresh five minutes early so a token never expires mid-flight.
        cache.put(scope, new Entry(token, Instant.now().plusSeconds(Math.max(60, expiresIn - 300))));
        return token;
    }

    private static String enc(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
```

## InboundTokenValidator

Azure Bot Service signs every inbound activity. This checks RS256 against the Bot Framework
JWKS, the audience against the blueprint app id, the issuer, and expiry with five minutes of
leeway — the same acceptance rules the Microsoft SDKs apply.

**This is the security boundary.** A tunnelled endpoint without it treats any request that
reaches the URL as a genuine Teams turn.

```java
package com.example.a365;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.jwk.source.RemoteJWKSet;
import com.nimbusds.jose.proc.JWSVerificationKeySelector;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.proc.DefaultJWTProcessor;

import java.net.URL;
import java.util.Date;
import java.util.Set;

/**
 * Validates the bearer token Azure Bot Service puts on every inbound activity.
 *
 * Mirrors what the Microsoft SDKs enforce: RS256 against the Bot Framework JWKS,
 * audience equal to this agent's blueprint app id, and five minutes of clock
 * leeway. Without this check the endpoint accepts anything that can reach it.
 */
public final class InboundTokenValidator {

    private static final String JWKS_URL = "https://login.botframework.com/v1/.well-known/keys";
    private static final Set<String> ISSUERS = Set.of("https://api.botframework.com");
    private static final long LEEWAY_SECONDS = 300;

    private final DefaultJWTProcessor<SecurityContext> processor;
    private final String expectedAudience;

    public InboundTokenValidator(String expectedAudience) throws Exception {
        this.expectedAudience = expectedAudience;
        JWKSource<SecurityContext> keys = new RemoteJWKSet<>(new URL(JWKS_URL));
        DefaultJWTProcessor<SecurityContext> p = new DefaultJWTProcessor<>();
        p.setJWSKeySelector(new JWSVerificationKeySelector<>(JWSAlgorithm.RS256, keys));
        this.processor = p;
    }

    /** @throws SecurityException if the token is absent, malformed, or not acceptable. */
    public JWTClaimsSet validate(String authorizationHeader) {
        if (authorizationHeader == null || !authorizationHeader.regionMatches(true, 0, "Bearer ", 0, 7)) {
            throw new SecurityException("Missing or malformed Authorization header");
        }
        String token = authorizationHeader.substring(7).trim();
        JWTClaimsSet claims;
        try {
            claims = processor.process(token, null);
        } catch (Exception e) {
            throw new SecurityException("Token signature not valid: " + e.getMessage(), e);
        }
        if (!claims.getAudience().contains(expectedAudience)) {
            throw new SecurityException("Unexpected audience: " + claims.getAudience());
        }
        if (!ISSUERS.contains(claims.getIssuer())) {
            throw new SecurityException("Unexpected issuer: " + claims.getIssuer());
        }
        Date expiry = claims.getExpirationTime();
        if (expiry == null || expiry.toInstant().plusSeconds(LEEWAY_SECONDS).isBefore(java.time.Instant.now())) {
            throw new SecurityException("Token expired");
        }
        return claims;
    }
}
```

## ConnectorClient

The reply goes to the `serviceUrl` on the inbound activity, not to a fixed host — the channel
decides where its conversations live. Hardcoding a host works in one environment and fails in
the next.

```java
package com.example.a365;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

/** Sends the reply back to the channel the activity arrived from. */
public final class ConnectorClient {

    public static final String CONNECTOR_SCOPE = "https://api.botframework.com/.default";

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10)).build();
    private final ObjectMapper mapper = new ObjectMapper();
    private final TokenProvider tokens;

    public ConnectorClient(TokenProvider tokens) {
        this.tokens = tokens;
    }

    /**
     * The reply goes to the serviceUrl carried on the inbound activity, not to a
     * fixed host: the channel decides where its own conversations live.
     */
    public void reply(JsonNode inboundActivity, String text) throws Exception {
        String serviceUrl = inboundActivity.path("serviceUrl").asText();
        String conversationId = inboundActivity.path("conversation").path("id").asText();
        String activityId = inboundActivity.path("id").asText();

        if (serviceUrl.isEmpty() || conversationId.isEmpty()) {
            throw new IllegalArgumentException("Activity has no serviceUrl or conversation id");
        }
        String base = serviceUrl.endsWith("/") ? serviceUrl : serviceUrl + "/";
        String url = base + "v3/conversations/" + enc(conversationId) + "/activities/" + enc(activityId);

        Map<String, Object> reply = new LinkedHashMap<>();
        reply.put("type", "message");
        reply.put("text", text);
        reply.put("from", inboundActivity.path("recipient"));
        reply.put("recipient", inboundActivity.path("from"));
        reply.put("conversation", inboundActivity.path("conversation"));
        reply.put("replyToId", activityId);

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .header("authorization", "Bearer " + tokens.getToken(CONNECTOR_SCOPE))
                .header("content-type", "application/json")
                .timeout(Duration.ofSeconds(30))
                .POST(HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(reply)))
                .build();

        HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() / 100 != 2) {
            throw new IllegalStateException("Reply rejected: HTTP " + response.statusCode()
                    + " " + response.body());
        }
    }

    private static String enc(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
```

## AgentHost

`answer(String)` is the seam: replace it with the call into the existing agent.

```java
package com.example.a365;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;

/**
 * Minimal Agent 365 host: serves /api/messages, validates the inbound token,
 * answers, and exports one span per turn.
 *
 * Register this endpoint on the blueprint with:
 *   a365 setup blueprint --update-endpoint https://<host>/api/messages --m365
 */
public final class AgentHost {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final InboundTokenValidator validator;
    private final ConnectorClient connector;
    private final ObservabilityExporter observability;
    private final boolean observabilityEnabled;
    private final int port;

    public AgentHost(int port, InboundTokenValidator validator, ConnectorClient connector,
                     ObservabilityExporter observability, boolean observabilityEnabled) {
        this.port = port;
        this.validator = validator;
        this.connector = connector;
        this.observability = observability;
        this.observabilityEnabled = observabilityEnabled;
    }

    public HttpServer start() throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/api/health", exchange -> respond(exchange, 200, "{\"status\":\"ok\"}"));
        server.createContext("/api/messages", this::handleMessage);
        server.setExecutor(Executors.newFixedThreadPool(8));
        server.start();
        System.out.println("Agent listening on http://localhost:" + port + "/api/messages");
        return server;
    }

    private void handleMessage(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            respond(exchange, 405, "{\"error\":\"method not allowed\"}");
            return;
        }
        try {
            validator.validate(exchange.getRequestHeaders().getFirst("Authorization"));
        } catch (SecurityException e) {
            // Anonymous or forged requests must never reach the agent.
            respond(exchange, 401, "{\"error\":\"unauthorized\"}");
            return;
        }

        long startNanos = System.currentTimeMillis() * 1_000_000L;
        String body;
        try (InputStream in = exchange.getRequestBody()) {
            body = new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }

        try {
            JsonNode activity = MAPPER.readTree(body);
            if ("message".equals(activity.path("type").asText())) {
                String text = activity.path("text").asText("");
                connector.reply(activity, answer(text));
            }
            respond(exchange, 200, "{}");
        } catch (Exception e) {
            System.err.println("Turn failed: " + e.getMessage());
            respond(exchange, 500, "{\"error\":\"internal error\"}");
        } finally {
            if (observabilityEnabled) {
                exportTurnSpan(startNanos);
            }
        }
    }

    /** Replace with the actual agent call. */
    protected String answer(String userText) {
        return "You said: " + userText;
    }

    private void exportTurnSpan(long startNanos) {
        try {
            List<Map<String, Object>> batch = ObservabilityExporter.newBatch();
            batch.add(observability.span(
                    "invoke_agent java-agent",
                    ObservabilityExporter.OPERATION_INVOKE_AGENT,
                    UUID.randomUUID().toString().replace("-", ""),
                    UUID.randomUUID().toString().replace("-", "").substring(0, 16),
                    startNanos,
                    System.currentTimeMillis() * 1_000_000L,
                    null));
            observability.export(batch, Map.of("service.name", "a365-java-agent"));
        } catch (Exception e) {
            System.err.println("[observability] span export skipped: " + e.getMessage());
        }
    }

    private static void respond(HttpExchange exchange, int status, String json) throws IOException {
        byte[] payload = json.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("content-type", "application/json");
        exchange.sendResponseHeaders(status, payload.length);
        exchange.getResponseBody().write(payload);
        exchange.close();
    }

    public static void main(String[] args) throws Exception {
        String tenantId = env("AGENT365_TENANT_ID");
        String clientId = env("AGENT365_CLIENT_ID");
        String clientSecret = env("AGENT365_CLIENT_SECRET");
        String agentId = System.getenv().getOrDefault("AGENT365_AGENT_ID", clientId);
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "3978"));
        boolean exporterOn = "true".equalsIgnoreCase(
                System.getenv().getOrDefault("ENABLE_A365_OBSERVABILITY_EXPORTER", "false"));

        TokenProvider tokens = new TokenProvider(tenantId, clientId, clientSecret);
        ObservabilityExporter exporter = new ObservabilityExporter(
                tenantId, agentId, false, tokens,
                "api://9b975845-388f-4429-889e-eab1ef63949c/.default");

        if (!exporterOn) {
            System.out.println("Observability instrumented but disabled: "
                    + "set ENABLE_A365_OBSERVABILITY_EXPORTER=true to export.");
        }
        new AgentHost(port, new InboundTokenValidator(clientId),
                new ConnectorClient(tokens), exporter, exporterOn).start();
        Thread.currentThread().join();
    }

    private static String env(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("Required environment variable not set: " + name);
        }
        return value;
    }
}
```
