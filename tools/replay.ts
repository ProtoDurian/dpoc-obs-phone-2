// Replay recorded bodies (from the CI runs) into a local Alloy: Faro -> faro.receiver, OTLP -> otlp receiver.
// Skips requests the tee answered 503 (collector-down test).
// With SYMS=<dir of <build_id>.symbols> it also plays the "edge symbolizer": every exception with a non-symbolic
// Dart stack (build_id + virt addresses) is decoded with llvm-symbolizer before it reaches Alloy, its frames are
// replaced by readable ones, and context gets error.group / error.top / error.symbolicated (Sentry-like grouping).
// usage: SYMS=dir bun replay.ts <file.ndjson>...   (a file whose name contains "otlp" goes to the OTLP receiver)
import { createHash } from "node:crypto";
import { decode } from "./symbolize.ts";

const SYMS = process.env.SYMS ?? "";
const files = Bun.argv.slice(2);
let ok = 0, bad = 0, skipped = 0, decoded = 0, grouped = 0;
const groups = new Map<string, { type: string; top: string; n: number }>();

const norm = (s: string) => s.replace(/[0-9a-f]{8,}/gi, "#").replace(/\d+/g, "N").slice(0, 120);
async function enrich(ex: any) {
  const frames: any[] = Array.isArray(ex.stacktrace?.frames) ? ex.stacktrace.frames : [];
  const raw = frames.map((f) => f.function ?? "").join("\n") || ex.context?.["error.stack_raw"] || "";
  ex.context ??= {};
  let group = "", top = "";
  if (SYMS && raw.includes("build_id")) {
    const d = await decode(raw, SYMS, ex.type);
    if (d.ok) {
      decoded++;
      ex.stacktrace = { frames: d.frames.map((f) => ({ function: f.fn, filename: f.file.replace(/.*\/app\//, ""), lineno: f.line, colno: 0, in_app: f.inApp })) };
      ex.context["error.symbolicated"] = "true";
      ex.context["error.build_id"] = d.buildId;
      group = d.group; top = d.top;
    } else ex.context["error.symbolicated"] = `false: ${d.why}`;
  }
  if (!group) { // symbolic stacks (debug/profile, iOS simulator) or no stack: in-app frames, else type + normalised message
    const inApp = frames.filter((f) => /spike_shop|\/lib\/main\.dart|main\.dart/.test(`${f.filename} ${f.function}`)).slice(0, 5).map((f) => f.function);
    const basis = inApp.length ? inApp : [norm(ex.value ?? "")];
    group = createHash("sha1").update([ex.type, ...basis].join("|")).digest("hex").slice(0, 12);
    top = inApp[0] ?? norm(ex.value ?? "");
  }
  ex.context["error.group"] = group;
  ex.context["error.top"] = top;
  grouped++;
  const g = groups.get(group) ?? { type: ex.type, top, n: 0 };
  g.n++; groups.set(group, g);
}

for (const file of files) {
  const target = file.includes("otlp") ? "http://127.0.0.1:4318/v1/traces" : "http://127.0.0.1:12347/collect";
  for (const line of (await Bun.file(file).text()).split("\n").filter(Boolean)) {
    const r = JSON.parse(line);
    if (r.down || r.method !== "POST" || !r.body) { skipped++; continue; }
    let body: string = r.body;
    if (!file.includes("otlp")) {
      const b = JSON.parse(body);
      for (const ex of b.exceptions ?? []) await enrich(ex);
      body = JSON.stringify(b);
    }
    const res = await fetch(target, { method: "POST", body, headers: { "content-type": "application/json", "x-api-key": "spike-key" } });
    if (res.ok) ok++; else { bad++; if (bad < 5) console.log(file, res.status, (await res.text()).slice(0, 200)); }
  }
}
console.log(`replayed ok=${ok} failed=${bad} skipped=${skipped} exceptions=${grouped} decoded=${decoded}`);
for (const [k, g] of [...groups].sort((a, b) => b[1].n - a[1].n)) console.log(`group ${k} n=${g.n} ${g.type} @ ${g.top}`);
