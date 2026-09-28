# The Streamable HTTP transport-behaviour pin (D-01a)

`02.1-03-PLAN.md` Task 1, Part A — `02.1-VALIDATION.md`'s fourth Wave 0 requirement. The vendored
JSON Schema (`schema-2026-07-28.json`) is the oracle for message *shape*; it cannot check
transport *behaviour* — whether a stream may carry keep-alives, whether closing it means anything,
whether a proxy should be told not to buffer it. Those are prose claims in the specification text,
not schema constraints, so D-01a's whole design rests on pinning that prose the same way the schema
itself is pinned: verbatim, with a source and a fetch date, so a later reader checks the quotation
against the current spec rather than against this file's paraphrase.

- **Source:** <https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http>
- **Fetched:** 2026-09-04

## The load-bearing quotations

**A server answers with JSON or an SSE stream, and the client must handle both — so choosing SSE
for `await` alone changes no tool contract:**

> If the body is a JSON-RPC *request*, the server MUST return either `Content-Type:
> application/json` (a single JSON object) or `Content-Type: text/event-stream` (an SSE response
> stream). The client MUST support both.

**Notifications may precede the final response on that stream, and the final response should
close it:**

> The server MAY send JSON-RPC notifications — for example, `notifications/progress` or
> `notifications/message` — before the final response. These notifications MUST relate to the
> originating client request. […] The final JSON-RPC response SHOULD terminate the stream.

**Keep-alives are explicitly encouraged on a long-lived stream — the exact line format used below
by `await`:**

> For long-lived streams — in particular the `subscriptions/listen` response stream — servers are
> encouraged to periodically emit an SSE comment line (a line beginning with a colon, e.g. `:\r\n`)
> as a keep-alive. This keeps the connection from being closed by intermediaries or client idle
> timeouts during quiet periods when no notifications are flowing. Per the SSE specification, any
> line beginning with a colon is a comment that carries no event data; clients must ignore such
> lines and must not treat them as malformed input.

**FINDING, recorded rather than silently adjusted for:** the quoted paragraph above names
`subscriptions/listen`'s stream "in particular" as the example long-lived stream — that request is
**not adopted** by this phase (D-01b: its notification types are list-changed/resource-updated, out
of scope per D-09b). `await`'s response stream is the other kind of long-lived stream this
specification describes (a single deferred `tools/call` response, not a `subscriptions/listen`
stream), and the keep-alive encouragement is written generally enough — "long-lived streams…in
particular" — to cover it: the mechanism (a periodic comment line) and its stated purpose (surviving
intermediary/client idle timeouts) apply identically to any long-lived SSE response, not only to
`subscriptions/listen`'s. `await` uses the identical `:\r\n` keep-alive line.

**The no-buffering header, sent whenever a stream opens:**

> When initiating an SSE stream, servers SHOULD include the `X-Accel-Buffering: no` header in the
> HTTP response. This instructs reverse proxies (such as nginx) to disable response buffering,
> ensuring that SSE events are delivered to clients immediately rather than being held in a buffer.
> Without this header, proxies may accumulate messages before sending them to the client,
> introducing unwanted latency and potentially breaking the real-time nature of SSE communication.

**Closing the stream IS the cancellation — there is no `notifications/cancelled` on this
transport:**

> Closing the SSE response stream MUST be treated by the server as cancellation of that request.
> Because each request has its own response stream, the transport-level disconnect is unambiguous.
> The server SHOULD stop work on the cancelled request as soon as practical and MUST NOT send any
> further messages for it.

(Confirmed elsewhere on the same page: "This revision of the core protocol defines no
client-to-server notifications over Streamable HTTP. The only client-sent notification in the core
protocol, `notifications/cancelled`, is used only on the stdio transport; on Streamable HTTP,
closing the SSE response stream is itself the cancellation signal and no `notifications/cancelled`
message is expected.")

**No resumption — which is also why no event carries an `id:` field:**

> Resumable SSE streams via `Last-Event-ID` are not supported.

And, in the Backward Compatibility section, for an older client that still sends the header this
revision retired:

> A `Last-Event-ID` header: ignore it; streams are not resumable.

## The exact SSE event framing — a FINDING, not an assumption

The plan asked this file to record "the exact event framing the specification prescribes for a
JSON-RPC message on that stream — the field names and their order." Having read the fetched text in
full (this page, and cross-checked against the parent `basic` overview page for anything more
general the transport page might be assuming): **the specification does not prescribe an explicit
`event:` field, or any field order, for a JSON-RPC message delivered on this stream.** Every
concrete SSE line format this revision names is the keep-alive comment line above (`:\r\n`) and,
inline in a resumability sentence, the retired `Last-Event-ID`/`id:` mechanism. Nowhere does the
page show `event: message` or any other named event type for a notification or a final response.

Read against the general Server-Sent Events specification the page itself points to ("Per the SSE
specification, any line beginning with a colon is a comment"), the framing this implies is the
SSE default: each JSON-RPC message (a notification, then the final response) is one **`data:`**
field carrying the JSON-encoded message, terminated by a blank line —

```
data: {"jsonrpc":"2.0","method":"notifications/message",...}

data: {"jsonrpc":"2.0","id":"...","result":{...}}

```

— with **no `event:` line** (so the client's default EventSource "message" handler applies, which
is the only handler a JSON-RPC-over-SSE client needs) and **no `id:` line** (resumability is not
supported on this revision, and shipping an `id:` on an event this server cannot honour a resume
request for would be exactly the invitation the prohibitions section warns against). `await.ex`
writes this framing — `data:` only, blank-line-terminated, no `event:`, no `id:` — and the keep-alive
comment line verbatim as quoted above.

## What this pins, and what it does not

This file is a **behaviour** pin — the transport rules `await.ex` must follow. It is not a byte-pin
like `schema-2026-07-28.json`/`SHA256SUMS`: the specification is served as rendered HTML, not a
versioned raw text file, so there is no stable byte sequence to hash the way the JSON Schema is
hashed. The discipline this file keeps instead: every claim above is a verbatim quotation with its
own paragraph of surrounding context, not a paraphrase — a later re-read of the live page is a
direct sentence-by-sentence comparison against what is written here, not a guess at whether meaning
drifted.
