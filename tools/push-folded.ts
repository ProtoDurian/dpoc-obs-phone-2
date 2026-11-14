// Push a folded-stacks file ("a;b;c <weight>" per line) to Pyroscope's /ingest.
// usage: bun push-folded.ts <file> <appName> <labels "k=v,k=v"> <units: samples|microseconds> [sampleRateHz]
const [file, app, labels, units, rate] = Bun.argv.slice(2);
const body = await Bun.file(file).text();
const until = Math.floor(Date.now() / 1000), from = until - 10;
const name = `${app}.cpu{${labels}}`;
const q = new URLSearchParams({ name, from: String(from), until: String(until), format: "folded", spyName: "spike", units: units === "microseconds" ? "microseconds" : "samples", aggregationType: "sum", sampleRate: rate ?? "100" });
const res = await fetch(`${process.env.PYRO ?? "http://127.0.0.1:4040"}/ingest?${q}`, { method: "POST", body, headers: { "content-type": "text/plain" } });
console.log(`push ${file} -> ${name}: ${res.status} ${await res.text()} lines=${body.split("\n").filter(Boolean).length}`);
