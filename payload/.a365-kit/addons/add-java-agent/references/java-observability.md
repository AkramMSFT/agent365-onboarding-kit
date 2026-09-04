# Java — Agent 365 observability

There is no Java distro, so spans go to the observability API directly. The API is OTLP over
HTTPS, but the JSON is **not** stock OTLP, and a standard OTLP encoder produces a body the
service will not read as intended.

## What the service expects

```
POST https://agent365.svc.cloud.microsoft/observability/tenants/{tenantId}/otlp/agents/{agentId}/traces?api-version=1
  authorization: Bearer <observability token>
  content-type: application/json
```

S2S agents post to `/observabilityService/...`; everything else is identical.

Three deviations from stock OTLP/JSON, all read from the shipped Python SDK and matched
byte-for-byte by the encoder below:

| | Stock OTLP/JSON | Agent 365 |
|---|---|---|
| Attributes | `[{"key":"k","value":{"stringValue":"v"}}]` | plain object: `{"k":"v"}` |
| `kind` | integer enum | name: `"SERVER"` |
| `status.code` | integer enum | name: `"OK"` |

Envelope shape:

```
resourceSpans[] -> { resource: { attributes }, scopeSpans[] -> { scope, spans[] } }
```

## The three attributes that decide whether a span survives

Every span **must** carry all three or the service drops it and still answers success:

| Attribute | Value |
|---|---|
| `gen_ai.operation.name` | one of `invoke_agent`, `execute_tool`, `output_messages`, `chat`, `apply_guardrail` |
| `microsoft.tenant.id` | tenant GUID |
| `gen_ai.agent.id` | the agent **instance** appId, not the blueprint id |

`microsoft.agent.user.id` is optional and carries the agentic user id.

This filter is how the pipeline ignores HTTP and database spans. It is also why a hand-rolled
exporter that omits the operation name sends batches forever and shows nothing in the portal.

## The token

The observability scope is `api://9b975845-388f-4429-889e-eab1ef63949c/.default`. On the
service-principal path `TokenProvider` from `java-endpoint.md` acquires it directly. The OBO
path exchanges the inbound user token, which the Java SDKs do not provide — an agent that
needs user-attributed traces has to implement that exchange itself.

## ObservabilityExporter

```java
package com.example.a365;

import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Posts spans to the Agent 365 observability API.
 *
 * The wire format is OTLP/JSON with two Microsoft-specific differences that a
 * standard OTLP encoder will get wrong:
 *   - attributes are a plain JSON object, NOT OTLP's [{key, value:{stringValue}}] array
 *   - kind and status.code are names ("SERVER", "OK"), not enum integers
 *
 * A span missing any of the three required attributes is dropped by the service
 * side with a success response, so an encoder bug here is silent.
 */
public final class ObservabilityExporter {

    public static final String OPERATION_INVOKE_AGENT = "invoke_agent";
    public static final String OPERATION_EXECUTE_TOOL = "execute_tool";
    public static final String OPERATION_CHAT = "chat";
    public static final String OPERATION_OUTPUT_MESSAGES = "output_messages";
    public static final String OPERATION_APPLY_GUARDRAIL = "apply_guardrail";

    private static final String DEFAULT_HOST = "https://agent365.svc.cloud.microsoft";

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10)).build();
    private final ObjectMapper mapper = new ObjectMapper();

    private final String host;
    private final String tenantId;
    private final String agentId;
    private final boolean useS2SEndpoint;
    private final TokenProvider tokens;
    private final String observabilityScope;

    public ObservabilityExporter(String tenantId, String agentId, boolean useS2SEndpoint,
                                 TokenProvider tokens, String observabilityScope) {
        this(DEFAULT_HOST, tenantId, agentId, useS2SEndpoint, tokens, observabilityScope);
    }

    public ObservabilityExporter(String host, String tenantId, String agentId, boolean useS2SEndpoint,
                                 TokenProvider tokens, String observabilityScope) {
        this.host = host;
        this.tenantId = tenantId;
        this.agentId = agentId;
        this.useS2SEndpoint = useS2SEndpoint;
        this.tokens = tokens;
        this.observabilityScope = observabilityScope;
    }

    String exportUrl() {
        String path = useS2SEndpoint ? "/observabilityService" : "/observability";
        return host + path + "/tenants/" + tenantId + "/otlp/agents/" + agentId + "/traces?api-version=1";
    }

    /**
     * Build one span. operationName must be one of the OPERATION_* constants or the
     * service drops it; the tenant and agent attributes are equally required.
     */
    public Map<String, Object> span(String name, String operationName, String traceId, String spanId,
                                    long startUnixNano, long endUnixNano, Map<String, Object> extraAttributes) {
        Map<String, Object> attributes = new LinkedHashMap<>();
        attributes.put("gen_ai.operation.name", operationName);
        attributes.put("microsoft.tenant.id", tenantId);
        attributes.put("gen_ai.agent.id", agentId);
        if (extraAttributes != null) {
            attributes.putAll(extraAttributes);
        }
        Map<String, Object> span = new LinkedHashMap<>();
        span.put("traceId", traceId);
        span.put("spanId", spanId);
        span.put("name", name);
        span.put("kind", "SERVER");
        span.put("startTimeUnixNano", startUnixNano);
        span.put("endTimeUnixNano", endUnixNano);
        span.put("attributes", attributes);
        span.put("status", Map.of("code", "OK", "message", ""));
        return span;
    }

    String envelope(List<Map<String, Object>> spans, Map<String, Object> resourceAttributes) throws Exception {
        Map<String, Object> scopeSpans = new LinkedHashMap<>();
        scopeSpans.put("scope", Map.of("name", "a365-java-agent", "version", "1.0.0"));
        scopeSpans.put("spans", spans);

        Map<String, Object> resourceSpan = new LinkedHashMap<>();
        resourceSpan.put("resource", Map.of("attributes",
                resourceAttributes == null ? Map.of() : resourceAttributes));
        resourceSpan.put("scopeSpans", List.of(scopeSpans));

        return mapper.writeValueAsString(Map.of("resourceSpans", List.of(resourceSpan)));
    }

    /** @return true when the service accepted the batch. Never throws: telemetry must not cost a turn. */
    public boolean export(List<Map<String, Object>> spans, Map<String, Object> resourceAttributes) {
        if (spans == null || spans.isEmpty()) {
            return true;
        }
        try {
            String body = envelope(spans, resourceAttributes);
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(exportUrl()))
                    .header("authorization", "Bearer " + tokens.getToken(observabilityScope))
                    .header("content-type", "application/json")
                    .timeout(Duration.ofSeconds(30))
                    .POST(HttpRequest.BodyPublishers.ofString(body))
                    .build();
            HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() / 100 == 2) {
                return true;
            }
            System.err.println("[observability] HTTP " + response.statusCode() + " " + response.body());
            return false;
        } catch (Exception e) {
            System.err.println("[observability] export failed: " + e.getMessage());
            return false;
        }
    }

    public static List<Map<String, Object>> newBatch() {
        return new ArrayList<>();
    }
}
```

## Wiring it into a turn

```java
long start = System.currentTimeMillis() * 1_000_000L;
// ... run the turn ...
var batch = ObservabilityExporter.newBatch();
batch.add(exporter.span("invoke_agent my-agent",
        ObservabilityExporter.OPERATION_INVOKE_AGENT,
        traceIdHex32, spanIdHex16, start,
        System.currentTimeMillis() * 1_000_000L, null));
exporter.export(batch, Map.of("service.name", "my-agent"));
```

`traceId` is 32 hex characters and `spanId` is 16. `export` never throws: a telemetry failure
must not cost a turn.

## Verification status

The encoder's output was compared field by field against the Python SDK's: same envelope
nesting, same span keys, attributes as a plain map, `kind` and `status.code` as names, and an
identical URL. **The batch has not been posted to a live tenant from Java** — the same
endpoint is confirmed working through the Python SDK, which is what this encoder was matched
against.

If the portal stays empty, check in this order: the exporter flag is `true`; the three
attributes are on every span; `gen_ai.agent.id` is the instance appId, not the blueprint id;
the token audience is the observability scope. Indexing also lags 15–90 minutes after the
first successful export.
