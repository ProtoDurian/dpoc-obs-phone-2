// Profile-mode build only: connect to the Dart VM service, pull CPU samples and the timeline,
// write folded stacks (for Pyroscope) and a top list. usage: bun vm-profile.ts <ws-or-http-url> <outPrefix>
const [url, out] = Bun.argv.slice(2);
const wsUrl = url.replace(/^http/, "ws").replace(/\/?$/, "/ws");
const ws = new WebSocket(wsUrl);
let id = 0; const pending = new Map<number, (v: any) => void>();
ws.onmessage = (e) => { const j = JSON.parse(String(e.data)); pending.get(j.id)?.(j); };
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; setTimeout(() => j(new Error("ws timeout")), 10000); });
const call = (method: string, params: any = {}) => new Promise<any>((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ jsonrpc: "2.0", id: i, method, params })); });
const vm = await call("getVM");
const flags = (await call("getFlagList")).result.flags;
const f = (n: string) => flags.find((x: any) => x.name === n)?.valueAsString;
console.log(`vm=${vm.result.version.slice(0, 40)} profiler=${f("profiler")} profile_period=${f("profile_period")}us`);
const iso = vm.result.isolates.find((i: any) => i.name === "main") ?? vm.result.isolates[0];
const t = Date.now();
const cs = await call("getCpuSamples", { isolateId: iso.id, timeOriginMicros: 0, timeExtentMicros: 9007199254740991 });
console.log(`getCpuSamples ms=${Date.now() - t} error=${JSON.stringify(cs.error ?? null)}`);
if (cs.result) {
  const r = cs.result;
  const name = (i: number) => { const fn = r.functions[i].function; const o = fn.owner?.name ? fn.owner.name + "." : ""; return (o + fn.name).replace(/[; ]/g, "_"); };
  const folded = new Map<string, number>();
  for (const s of r.samples) {
    if (!s.stack?.length) continue;
    const path = s.stack.slice().reverse().map(name).join(";");
    folded.set(path, (folded.get(path) ?? 0) + 1);
  }
  await Bun.write(`${out}.folded`, [...folded].map(([k, v]) => `${k} ${v}`).join("\n") + "\n");
  const self = new Map<string, number>();
  for (const s of r.samples) if (s.stack?.length) { const n = name(s.stack[0]); self.set(n, (self.get(n) ?? 0) + 1); }
  const top = [...self].sort((a, b) => b[1] - a[1]).slice(0, 15).map(([k, v]) => `${v}\t${k}`).join("\n");
  const json = JSON.stringify(r);
  await Bun.write(`${out}.top.txt`, `samples=${r.sampleCount} period_us=${r.samplePeriod} functions=${r.functions.length} reply_bytes=${json.length}\n${top}\n`);
  console.log(`samples=${r.sampleCount} reply_bytes=${json.length}`);
}
const tl = await call("getVMTimeline", {});
if (tl.result) {
  const ev = tl.result.traceEvents ?? [];
  const byName = new Map<string, { n: number; us: number }>();
  for (const e of ev) if (e.ph === "X" || e.ph === "B") { const k = `${e.cat}:${e.name}`; const v = byName.get(k) ?? { n: 0, us: 0 }; v.n++; v.us += e.dur ?? 0; byName.set(k, v); }
  await Bun.write(`${out}.timeline-top.txt`, `events=${ev.length}\n` + [...byName].sort((a, b) => b[1].us - a[1].us).slice(0, 30).map(([k, v]) => `${(v.us / 1000).toFixed(1)}ms\t${v.n}\t${k}`).join("\n") + "\n");
  await Bun.write(`${out}.timeline.json`, JSON.stringify(tl.result));
  console.log(`timeline events=${ev.length}`);
} else console.log(`timeline error=${JSON.stringify(tl.error)}`);
ws.close();
