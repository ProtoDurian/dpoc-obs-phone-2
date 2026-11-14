// Small backend for the g4 spike: 3 endpoints, one slow, real OTel server spans.
import { context, propagation, trace, SpanKind, SpanStatusCode } from "@opentelemetry/api";
import { BasicTracerProvider, BatchSpanProcessor } from "@opentelemetry/sdk-trace-base";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { W3CTraceContextPropagator } from "@opentelemetry/core";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";

const provider = new BasicTracerProvider({
  resource: resourceFromAttributes({ "service.name": "spike-api", "service.version": "1.0.0" }),
  spanProcessors: [new BatchSpanProcessor(new OTLPTraceExporter({ url: process.env.OTLP_URL ?? "http://127.0.0.1:31319/v1/traces" }), { scheduledDelayMillis: 500 })],
});
trace.setGlobalTracerProvider(provider);
propagation.setGlobalPropagator(new W3CTraceContextPropagator());
context.setGlobalContextManager(new AsyncLocalStorageContextManager().enable());
const tracer = trace.getTracer("spike-api");

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "traceparent, tracestate, content-type, x-faro-session-id",
  "access-control-allow-methods": "GET, OPTIONS",
  "timing-allow-origin": "*",
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log: string[] = [];

async function route(path: string): Promise<unknown> {
  switch (path) {
    case "/health":
      return { ok: true };
    case "/api/user":
      await sleep(30);
      return { id: "u-42", name: "Ada", plan: "pro" };
    case "/api/orders":
      // the slow call: a slow "db query" child span
      await tracer.startActiveSpan("db.query orders.list", { kind: SpanKind.CLIENT, attributes: { "db.system.name": "postgresql" } }, async (s) => {
        await sleep(1200);
        s.end();
      });
      return Array.from({ length: 5 }, (_, i) => ({ id: i, total: 10 * i }));
    case "/api/catalog":
      await sleep(40);
      return Array.from({ length: 3000 }, (_, i) => ({ id: i, name: `Item ${i}`, price: (i * 7) % 100 }));
    default:
      return null;
  }
}

Bun.serve({
  port: 31380, hostname: "0.0.0.0",
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (url.pathname === "/_seen") return Response.json(log, { headers: cors });
    const headers: Record<string, string> = {};
    req.headers.forEach((v, k) => (headers[k] = v));
    const parent = propagation.extract(context.active(), headers);
    return context.with(parent, () =>
      tracer.startActiveSpan(`GET ${url.pathname}`, { kind: SpanKind.SERVER, attributes: { "http.request.method": "GET", "url.path": url.pathname, "http.route": url.pathname } }, async (span) => {
        const body = await route(url.pathname);
        const status = body === null ? 404 : 200;
        span.setAttribute("http.response.status_code", status);
        if (status >= 400) span.setStatus({ code: SpanStatusCode.ERROR });
        const sc = span.spanContext();
        log.push(`${new Date().toISOString()} ${url.pathname} traceparent_in=${headers["traceparent"] ?? "-"} server_trace=${sc.traceId} server_span=${sc.spanId} ua=${(headers["user-agent"] ?? "-").slice(0, 60)}`);
        span.end();
        return Response.json(body, { status, headers: cors });
      }),
    );
  },
});
console.log("spike-api on :31380");
