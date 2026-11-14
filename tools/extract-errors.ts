// From the recorded Faro bodies, write each exception's stack as text (one file per error) for
// `flutter symbolize`, plus a summary TSV. usage: bun extract-errors.ts <faro-bodies.ndjson> <outDir>
import { mkdirSync } from "node:fs";
const [inp, outDir] = Bun.argv.slice(2);
mkdirSync(outDir, { recursive: true });
const rows: string[] = ["n\ttype\tvalue\tframes\tobfuscated\tsession\tplatform\tbuild_mode\tscenario"];
let n = 0;
for (const line of (await Bun.file(inp).text()).split("\n").filter(Boolean)) {
  const rec = JSON.parse(line); let b: any; try { b = JSON.parse(rec.body); } catch { continue; }
  const meta = b.meta ?? {}; const attrs = meta.session?.attributes ?? {};
  for (const ex of b.exceptions ?? []) {
    n++;
    const frames = ex.stacktrace?.frames ?? [];
    const text = frames.map((f: any) => (f.filename ? `${f.function} (${f.filename}:${f.lineno}:${f.colno})` : f.function)).join("\n");
    const raw = ex.context?.["error.stack_raw"] ?? ex.context?.stacktrace ?? "";
    const obf = /\*\*\* \*\*\*|_kDartIsolateSnapshotInstructions|build_id/.test(text + raw);
    await Bun.write(`${outDir}/err-${String(n).padStart(3, "0")}.txt`, (raw && raw.length > text.length ? raw : text) + "\n");
    await Bun.write(`${outDir}/err-${String(n).padStart(3, "0")}.json`, JSON.stringify({ meta: { session: meta.session, app: meta.app, os: meta.os ?? meta.device, sdk: meta.sdk }, exception: ex }, null, 1));
    rows.push([n, ex.type, String(ex.value).slice(0, 80).replace(/\s+/g, " "), frames.length, obf, meta.session?.id, attrs.client_kind, attrs.build_mode, attrs.scenario].join("\t"));
  }
}
await Bun.write(`${outDir}/summary.tsv`, rows.join("\n") + "\n");
console.log(`errors=${n}`);
