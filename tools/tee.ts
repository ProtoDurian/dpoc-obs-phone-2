// Recording proxy: forwards every request to a target and appends {ts, path, headers, body} to an NDJSON file.
// Used in front of Alloy's faro.receiver (phone app) and OTLP (backend) so the exact bytes can be replayed later.
// usage: bun tee.ts <listenPort> <targetBase> <out.ndjson> [--down-file <path>]  (if the file exists, answer 503 = collector down)
const [port, target, out] = Bun.argv.slice(2);
const downIdx = Bun.argv.indexOf("--down-file");
const downFile = downIdx > 0 ? Bun.argv[downIdx + 1] : null;
const sink = Bun.file(out).writer();
const keep = ["content-type", "user-agent", "x-faro-session-id", "x-api-key", "x-forwarded-for", "traceparent"];
Bun.serve({
  port: Number(port),
  hostname: "0.0.0.0",
  async fetch(req) {
    const url = new URL(req.url);
    const body = req.method === "GET" || req.method === "HEAD" ? "" : await req.text();
    const h: Record<string, string> = {};
    req.headers.forEach((v, k) => { if (keep.includes(k)) h[k] = v; });
    const down = downFile ? await Bun.file(downFile).exists() : false;
    sink.write(JSON.stringify({ ts: Date.now(), method: req.method, path: url.pathname + url.search, headers: h, down, body }) + "\n");
    sink.flush();
    if (down) return new Response("collector down (spike)", { status: 503 });
    const res = await fetch(target + url.pathname + url.search, { method: req.method, headers: req.headers, body: body || undefined });
    return new Response(await res.arrayBuffer(), { status: res.status, headers: res.headers });
  },
});
console.log(`tee :${port} -> ${target} -> ${out}`);
