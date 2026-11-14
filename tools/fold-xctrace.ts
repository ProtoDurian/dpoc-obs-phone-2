// Convert `xctrace export --xpath ...table[@schema="time-profile"]` XML into folded stacks (root;...;leaf weight_ms).
// xctrace de-duplicates with id/ref: <frame id=.. name=..> once, then <frame ref=..>; same for <backtrace> and <thread>.
// usage: bun fold-xctrace.ts <time-profile.xml> <out.folded> [threadFilter regex]
const [inp, out, thr] = Bun.argv.slice(2);
const xml = await Bun.file(inp).text();
const frameName = new Map<string, string>();
const btFrames = new Map<string, string[]>();
const threadName = new Map<string, string>();
const unesc = (s: string) => s.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'");
const folded = new Map<string, number>();
const filter = thr ? new RegExp(thr) : null;
for (const row of xml.split("<row>").slice(1)) {
  let tname = "";
  const td = row.match(/<thread id="(\d+)" fmt="([^"]*)"/);
  if (td) { threadName.set(td[1], unesc(td[2])); tname = unesc(td[2]); }
  else { const tr = row.match(/<thread ref="(\d+)"/); if (tr) tname = threadName.get(tr[1]) ?? ""; }
  tname = tname.replace(/ 0x[0-9a-f]+ \(.*\)$/, "").replace(/\s+/g, "_");
  if (filter && !filter.test(tname)) continue;
  const w = Number(row.match(/<weight [^>]*>(\d+)</)?.[1] ?? row.match(/<weight ref="\d+"/) ? 1000000 : 0) || 1000000;
  let frames: string[] = [];
  const bd = row.match(/<backtrace id="(\d+)"[^>]*>([\s\S]*?)<\/backtrace>/);
  if (bd) {
    for (const f of bd[2].matchAll(/<frame (?:id="(\d+)" name="([^"]*)"|ref="(\d+)")/g)) {
      if (f[1]) frameName.set(f[1], unesc(f[2]));
      frames.push(f[1] ? unesc(f[2]) : frameName.get(f[3]) ?? "?");
    }
    btFrames.set(bd[1], frames);
  } else {
    const br = row.match(/<backtrace ref="(\d+)"/);
    if (br) frames = btFrames.get(br[1]) ?? [];
  }
  if (!frames.length) continue;
  const names = frames.map((n) => (/^0x[0-9a-f]+$/.test(n) ? "[unsymbolized JIT/Dart code]" : n).replace(/;/g, ":").replace(/\s+/g, "_"));
  // collapse runs of unsymbolized frames
  const collapsed = names.filter((n, i) => !(n === "[unsymbolized JIT/Dart code]" && names[i - 1] === n));
  const key = [tname, ...collapsed.reverse()].join(";");
  folded.set(key, (folded.get(key) ?? 0) + Math.round(w / 1e6));
}
await Bun.write(out, [...folded].map(([k, v]) => `${k} ${v}`).join("\n") + "\n");
console.log(`folded_lines=${folded.size} total_ms=${[...folded.values()].reduce((a, b) => a + b, 0)}`);
