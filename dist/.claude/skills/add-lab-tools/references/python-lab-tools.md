# Lab tools -- Python (OpenAI Agents SDK)

Verified on a live hosted agent, 2026-09-04: 11 tools total, agent used `summarize_url_content` in Teams. These are `@function_tool` functions -- no MCP, no consent, no tokens.

## `src/lab_tools.py`

Create this file verbatim. `httpx` is already a dependency of A365 Python agents; nothing else is needed (base64/hashlib/re/urllib are stdlib).

```python
"""
Lab tools for the Northwind agent -- local @function_tool capabilities beyond the
built-in expense tools and the Work IQ MCP servers.

These are plain Python functions the model can call directly: no Entra consent, no
tokens, no tenant setup. They exist to exercise agent behaviour and Microsoft's
detection stack (Defender, Purview) on THIS tenant, under the operator's authority.

Grouped as:
  * Web        fetch_url / summarize_url_content   -- the classic prompt-injection
               and data-egress surface; note the guardrails below.
  * Encoding   encode_text / decode_text / hash_text
  * Text       transform_text / count_text / regex_extract

fetch_url is deliberately capped (size, time, redirects, http/https only). It does
NOT block private/loopback targets -- in a security lab that SSRF surface is often
the point; if you want it locked down, add an allowlist here.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import re
import urllib.parse

import httpx
from agents import function_tool

_MAX_FETCH_BYTES = 200_000
_FETCH_TIMEOUT_S = 15.0


# --------------------------------------------------------------------------
# Web
# --------------------------------------------------------------------------

@function_tool
def fetch_url(url: str) -> str:
    """Fetch a web page or API over HTTP/HTTPS and return its text content.

    Use this to open a link the user gives you, read a page, or pull data from a URL.
    Returns up to ~200 KB of text. Only http:// and https:// are allowed.
    """
    if not re.match(r"^https?://", url.strip(), re.IGNORECASE):
        return "Refused: only http:// and https:// URLs are supported."
    try:
        with httpx.Client(timeout=_FETCH_TIMEOUT_S, follow_redirects=True, max_redirects=5) as c:
            r = c.get(url.strip(), headers={"User-Agent": "NorthwindAgent/1.0"})
        body = r.text[:_MAX_FETCH_BYTES]
        note = "" if len(r.text) <= _MAX_FETCH_BYTES else f"\n\n[truncated to {_MAX_FETCH_BYTES} chars]"
        return f"HTTP {r.status_code} {r.headers.get('content-type','')}\nfinal_url: {r.url}\n\n{body}{note}"
    except Exception as e:  # noqa: BLE001
        return f"Fetch failed: {type(e).__name__}: {e}"


@function_tool
def summarize_url_content(url: str) -> str:
    """Fetch a URL and return its readable text with the HTML stripped, ready to summarise.

    Same fetch as fetch_url, but tags and scripts are removed so you can summarise the
    page in your own words. Only http:// and https:// are allowed.
    """
    raw = fetch_url(url)  # type: ignore[operator]  # function_tool wraps the callable
    if raw.startswith(("Refused", "Fetch failed")):
        return raw
    # Drop the header block fetch_url prepends, then strip markup.
    body = raw.split("\n\n", 1)[-1]
    body = re.sub(r"(?is)<(script|style|head).*?</\1>", " ", body)
    text = re.sub(r"(?s)<[^>]+>", " ", body)
    text = urllib.parse.unquote(re.sub(r"\s+", " ", text)).strip()
    return text[:_MAX_FETCH_BYTES] or "No readable text found on the page."


# --------------------------------------------------------------------------
# Encoding
# --------------------------------------------------------------------------

@function_tool
def encode_text(text: str, scheme: str) -> str:
    """Encode text. scheme = base64 | base64url | hex | url | rot13."""
    s = scheme.strip().lower()
    b = text.encode("utf-8")
    try:
        if s == "base64":
            return base64.b64encode(b).decode()
        if s == "base64url":
            return base64.urlsafe_b64encode(b).decode()
        if s == "hex":
            return b.hex()
        if s == "url":
            return urllib.parse.quote(text)
        if s == "rot13":
            import codecs
            return codecs.encode(text, "rot13")
        return f"Unknown scheme '{scheme}'. Use base64, base64url, hex, url, or rot13."
    except Exception as e:  # noqa: BLE001
        return f"Encode failed: {type(e).__name__}: {e}"


@function_tool
def decode_text(text: str, scheme: str) -> str:
    """Decode text. scheme = base64 | base64url | hex | url | rot13."""
    s = scheme.strip().lower()
    try:
        if s in ("base64", "base64url"):
            pad = text + "=" * (-len(text) % 4)
            fn = base64.urlsafe_b64decode if s == "base64url" else base64.b64decode
            return fn(pad.encode()).decode("utf-8", "replace")
        if s == "hex":
            return bytes.fromhex(text.strip()).decode("utf-8", "replace")
        if s == "url":
            return urllib.parse.unquote(text)
        if s == "rot13":
            import codecs
            return codecs.encode(text, "rot13")
        return f"Unknown scheme '{scheme}'. Use base64, base64url, hex, url, or rot13."
    except (binascii.Error, ValueError) as e:
        return f"Decode failed: not valid {scheme}: {e}"
    except Exception as e:  # noqa: BLE001
        return f"Decode failed: {type(e).__name__}: {e}"


@function_tool
def hash_text(text: str, algo: str = "sha256") -> str:
    """Hash text. algo = md5 | sha1 | sha256 | sha512."""
    a = algo.strip().lower()
    if a not in ("md5", "sha1", "sha256", "sha512"):
        return f"Unknown algorithm '{algo}'. Use md5, sha1, sha256, or sha512."
    return hashlib.new(a, text.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------
# Text
# --------------------------------------------------------------------------

@function_tool
def transform_text(text: str, operation: str) -> str:
    """Transform text. operation = upper | lower | title | reverse | strip | collapse-space."""
    op = operation.strip().lower()
    ops = {
        "upper": str.upper, "lower": str.lower, "title": str.title,
        "reverse": lambda s: s[::-1], "strip": str.strip,
        "collapse-space": lambda s: re.sub(r"\s+", " ", s).strip(),
    }
    fn = ops.get(op)
    return fn(text) if fn else f"Unknown operation '{operation}'. Use one of: {', '.join(ops)}."


@function_tool
def count_text(text: str) -> str:
    """Count characters, words and lines in some text."""
    return (f"characters: {len(text)}  "
            f"words: {len(text.split())}  "
            f"lines: {len(text.splitlines()) or (1 if text else 0)}")


@function_tool
def regex_extract(text: str, pattern: str) -> str:
    """Return all matches of a regular expression in the text (max 100), one per line."""
    try:
        matches = re.findall(pattern, text)
    except re.error as e:
        return f"Invalid regex: {e}"
    if not matches:
        return "No matches."
    flat = ["".join(m) if isinstance(m, tuple) else m for m in matches][:100]
    return "\n".join(flat)


LAB_TOOLS = [
    fetch_url, summarize_url_content,
    encode_text, decode_text, hash_text,
    transform_text, count_text, regex_extract,
]
```

## Wiring into the agent

In the agent module (`src/agent.py` in the verified project), import the tool list and **append** it -- keep the built-in and Work IQ tools:

```python
from agents import Agent, Runner, function_tool
try:
    from src.lab_tools import LAB_TOOLS
except ImportError:            # when run as a top-level module
    from lab_tools import LAB_TOOLS

# ... existing tool definitions ...

expenses_agent = Agent(
    name="...",
    instructions=(
        # add one line so the model actually uses them:
        "You also have local utility tools: fetch a URL or summarise a web page "
        "(fetch_url, summarize_url_content), encode/decode/hash text (encode_text, "
        "decode_text, hash_text), and inspect or transform text (transform_text, "
        "count_text, regex_extract). Use them when asked to open a link, decode a "
        "value, or manipulate text. "
        # ... rest of the existing instructions ...
    ),
    tools=[look_up_expense_report, list_reports_for_employee, get_policy, *LAB_TOOLS],
)
```

To ship only some groups, import the group lists instead of `LAB_TOOLS` (split the
`LAB_TOOLS = [...]` line in the module into `WEB_TOOLS`, `ENCODING_TOOLS`, `TEXT_TOOLS`
and compose).

## Verify

```bash
python -c "import src.agent as a; print(len(a.expenses_agent.tools), [t.name for t in a.expenses_agent.tools])"
```

Expect the count to rise by the number of tools added, with the originals still present.
Restart the host if it is running -- Python does not hot-reload.

## Guards already in the code

- `fetch_url`: http/https only, 15s timeout, 200 KB cap, max 5 redirects. It does **not**
  block private/loopback targets -- add an allowlist at the top of the function if you
  need that. It is egress surface by design.
- `decode_text` restores base64 padding and replaces undecodable bytes rather than throwing.
- `regex_extract` caps at 100 matches and reports invalid patterns instead of raising.
