// Replay recorded bodies (from the CI runs) into a local Alloy: Faro -> faro.receiver, OTLP -> otlp receiver.
// Skips requests the tee answered 503 (collector-down test). usage: bun replay.ts <faro.ndjson> <otlp.ndjson>
const [faro, otlp] = Bun.argv.slice(2);
let ok = 0, bad = 0, skipped = 0;
for (const [file, target] of [[faro, "http://127.0.0.1:12347/collect"], [otlp, "http://127.0.0.1:4318/v1/traces"]] as const) {
  if (!file || !(await Bun.file(file).exists())) continue;
  for (const line of (await Bun.file(file).text()).split("\n").filter(Boolean)) {
    const r = JSON.parse(line);
    if (r.down || r.method !== "POST" || !r.body) { skipped++; continue; }
    const res = await fetch(target, { method: "POST", body: r.body, headers: { "content-type": "application/json" } });
    if (res.ok) ok++; else { bad++; if (bad < 5) console.log(file, res.status, (await res.text()).slice(0, 200)); }
  }
}
console.log(`replayed ok=${ok} failed=${bad} skipped=${skipped}`);
