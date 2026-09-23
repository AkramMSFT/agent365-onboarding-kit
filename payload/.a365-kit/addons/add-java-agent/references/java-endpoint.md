# Java — Agent 365 hosting layer

First compiled against JDK 21 and run on 2026-09-11 (`/api/health` 200, anonymous POST 401,
forged bearer 401, GET 405); a Copilot CLI dry run then reproduced it on a fresh Maven project.
The classes below are the later audited revision.

The original host was compiled against **JDK 21** and run: `/api/health` returned 200,
an anonymous POST to `/api/messages` returns 401, a forged bearer returns 401, and a GET
returns 405. What has **not** been exercised against a tenant is a real inbound activity
from Teams and a real reply through the Connector API — those need a published agent.

The current five reference classes also passed a **fresh compile-only check** with
Microsoft OpenJDK **21.0.12.1**, Maven **3.9.11** and `javac --release 17`, using the dependency
versions below. This check did not start the host or call a tenant, model or external service.

Java 17 is the floor (`java.net.http.HttpClient`, records, `Map.of`).
This is a **commercial-cloud, single-tenant Bot Connector** implementation, not a complete
Java replacement for every Agents SDK authentication flow. Verify the registered inbound
audience and outbound client identity from your connection configuration; they need not
be the same. Emulator, agentic Entra issuers and channel-specific endorsement policies need
their own supported validation implementation before exposing those flows.

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
| `AGENT365_CLIENT_ID` | app/client id for the outbound single-tenant credential |
| `AGENT365_CLIENT_SECRET` | blueprint client secret |
| `AGENT365_AUDIENCE` | registered inbound bot/endpoint audience; confirm it, do not assume it equals the client id |
| `AGENT365_AGENT_ID` | instance appId for telemetry; required when export is enabled |
| `PORT` | listen port, default 3978 |
| `ENABLE_A365_OBSERVABILITY_EXPORTER` | `true` to export |

These `AGENT365_*` names are adapter-specific, not keys that `a365 setup` automatically
creates. Map the generated connection/identity configuration into process environment
variables. Java does **not** load `.env` automatically; export them in the launching shell or
configure them in the host's secret/configuration provider.

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
        if (token.isBlank() || expiresIn <= 0) {
            throw new IllegalStateException("Token response has no usable access token or lifetime");
        }

        // Refresh five minutes early so a token never expires mid-flight.
        cache.put(scope, new Entry(token, Instant.now().plusSeconds(Math.max(0, expiresIn - 300))));
        return token;
    }

    private static String enc(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
```

## InboundTokenValidator

Azure Bot Service signs every inbound activity. This checks RS256 against the Bot Framework
JWKS, the configured inbound audience, issuer, expiry and not-before with five minutes of
leeway. After parsing the activity, it also binds its `serviceUrl` to the signed claim before
any reply credential is sent.

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
import com.nimbusds.jwt.proc.DefaultJWTClaimsVerifier;

import java.net.URI;
import java.net.URL;
import java.util.Set;

/**
 * Validates the bearer token Azure Bot Service puts on every inbound activity.
 *
 * Validates RS256 against the Bot Framework JWKS,
 * the configured inbound audience, and five minutes of clock
 * leeway. Without this check the endpoint accepts anything that can reach it.
 */
public final class InboundTokenValidator {

    private static final String JWKS_URL = "https://login.botframework.com/v1/.well-known/keys";
    private static final Set<String> ISSUERS = Set.of("https://api.botframework.com");
    private final DefaultJWTProcessor<SecurityContext> processor;
    private final String expectedAudience;

    public InboundTokenValidator(String expectedAudience) throws Exception {
        this.expectedAudience = expectedAudience;
        JWKSource<SecurityContext> keys = new RemoteJWKSet<>(new URL(JWKS_URL));
        DefaultJWTProcessor<SecurityContext> p = new DefaultJWTProcessor<>();
        p.setJWSKeySelector(new JWSVerificationKeySelector<>(JWSAlgorithm.RS256, keys));
        DefaultJWTClaimsVerifier<SecurityContext> claimsVerifier = new DefaultJWTClaimsVerifier<>(
                new JWTClaimsSet.Builder().issuer("https://api.botframework.com").build(),
                Set.of("iss", "aud", "exp", "nbf"));
        claimsVerifier.setMaxClockSkew(300);
        p.setJWTClaimsSetVerifier(claimsVerifier);
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
        return claims;
    }

    public void validateServiceUrl(JWTClaimsSet claims, String serviceUrl) {
        try {
            String signedUrl = claims.getStringClaim("serviceurl");
            if (signedUrl == null) signedUrl = claims.getStringClaim("serviceUrl");
            URI target = URI.create(serviceUrl);
            if (!"https".equalsIgnoreCase(target.getScheme()) || target.getHost() == null
                    || target.getUserInfo() != null || target.getFragment() != null
                    || target.getQuery() != null || signedUrl == null
                    || !target.equals(URI.create(signedUrl))) {
                throw new SecurityException("Activity serviceUrl does not match the signed HTTPS URL");
            }
        } catch (Exception e) {
            throw new SecurityException("Invalid activity serviceUrl", e);
        }
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

        if (serviceUrl.isEmpty() || conversationId.isEmpty() || activityId.isEmpty()) {
            throw new IllegalArgumentException("Reply requires serviceUrl, conversation id and activity id");
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
        return URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20");
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
import com.nimbusds.jwt.JWTClaimsSet;

import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;

/**
 * Minimal Agent 365 host: serves /api/messages, validates the inbound token,
 * answers, and exports one span per turn.
 *
 * Register this endpoint on the blueprint with:
 *   a365 setup blueprint --update-endpoint https://<host>/api/messages --m365
 */
public final class AgentHost implements AutoCloseable {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final InboundTokenValidator validator;
    private final ConnectorClient connector;
    private final ObservabilityExporter observability;
    private final boolean observabilityEnabled;
    private final int port;
    private HttpServer server;
    private ExecutorService executor;

    public AgentHost(int port, InboundTokenValidator validator, ConnectorClient connector,
                     ObservabilityExporter observability, boolean observabilityEnabled) {
        this.port = port;
        this.validator = validator;
        this.connector = connector;
        this.observability = observability;
        this.observabilityEnabled = observabilityEnabled;
    }

    public HttpServer start() throws IOException {
        if (server != null) throw new IllegalStateException("Host already started");
        server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/api/health", exchange -> respond(exchange, 200, "{\"status\":\"ok\"}"));
        server.createContext("/api/messages", this::handleMessage);
        executor = Executors.newFixedThreadPool(8);
        server.setExecutor(executor);
        server.start();
        System.out.println("Agent listening on http://localhost:" + port + "/api/messages");
        return server;
    }

    private void handleMessage(HttpExchange exchange) throws IOException {
        if (!"/api/messages".equals(exchange.getRequestURI().getPath())) {
            respond(exchange, 404, "{\"error\":\"not found\"}");
            return;
        }
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            respond(exchange, 405, "{\"error\":\"method not allowed\"}");
            return;
        }
        JWTClaimsSet claims;
        try {
            claims = validator.validate(exchange.getRequestHeaders().getFirst("Authorization"));
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
            validator.validateServiceUrl(claims, activity.path("serviceUrl").asText());
            if ("message".equals(activity.path("type").asText())) {
                String text = activity.path("text").asText("");
                connector.reply(activity, answer(text));
            }
            respond(exchange, 200, "{}");
        } catch (SecurityException e) {
            respond(exchange, 401, "{\"error\":\"unauthorized\"}");
        } catch (Exception e) {
            System.err.println("Turn failed: " + e.getMessage());
            respond(exchange, 500, "{\"error\":\"internal error\"}");
        } finally {
            if (observabilityEnabled) {
                exportTurnSpan(startNanos);
            }
        }
    }

    @Override
    public void close() {
        if (server != null) server.stop(1);
        if (executor != null) executor.shutdownNow();
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
        String audience = env("AGENT365_AUDIENCE");
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "3978"));
        boolean exporterOn = "true".equalsIgnoreCase(
                System.getenv().getOrDefault("ENABLE_A365_OBSERVABILITY_EXPORTER", "false"));
        String agentId = exporterOn ? env("AGENT365_AGENT_ID") : "";

        TokenProvider tokens = new TokenProvider(tenantId, clientId, clientSecret);
        ObservabilityExporter exporter = new ObservabilityExporter(
                tenantId, agentId, true, tokens,
                "api://9b975845-388f-4429-889e-eab1ef63949c/.default");

        if (!exporterOn) {
            System.out.println("Observability instrumented but disabled: "
                    + "set ENABLE_A365_OBSERVABILITY_EXPORTER=true to export.");
        }
        AgentHost host = new AgentHost(port, new InboundTokenValidator(audience),
                new ConnectorClient(tokens), exporter, exporterOn);
        Runtime.getRuntime().addShutdownHook(new Thread(host::close));
        host.start();
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

The `TokenProvider` uses client credentials, so `main` selects the **S2S**
`/observabilityService` exporter route. A delegated exporter needs an actual OBO token
provider, not just changing that boolean. Closing `HttpServer` alone does not terminate
the custom executor; the shutdown hook closes both.

API evidence: [Bot Connector authentication](https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-connector-authentication)
requires validity-period and signed service-URL checks. Offline syntax/contract checks do
not establish successful Teams delivery, Connector replies, endorsement handling or live
telemetry export.
