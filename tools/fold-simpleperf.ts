// Convert `simpleperf report-sample --show-callchain` text to folded stacks (root;...;leaf count).
// usage: bun fold-simpleperf.ts <in.txt> <out.folded> [threadFilter regex]
const [inp, out, thr] = Bun.argv.slice(2);
const text = await Bun.file(inp).text();
const re = thr ? new RegExp(thr) : null;
const folded = new Map<string, number>();
let n = 0, kept = 0;
for (const block of text.split(/\nsample:/)) {
  const tname = block.match(/thread_name:\s*(.*)/)?.[1]?.trim() ?? "?";
  const frames: string[] = [];
  // each frame line: "  <addr>\t<symbol>\t<dso>" possibly with spaces; keep symbol + short dso
  for (const m of block.matchAll(/^\s+([0-9a-f]+)\s+(.+?)\s+(\S+)$/gm)) {
    const sym = m[2].trim(); const dso = m[3].split("/").pop()!.replace(/!.*$/, "");
    frames.push(`${sym === "unknown" || /^[0-9a-f]+$/.test(sym) ? "?" : sym}[${dso}]`.replace(/[; ]/g, "_"));
  }
  if (!frames.length) continue;
  n++;
  if (re && !re.test(tname)) continue;
  kept++;
  const path = [tname.replace(/[; ]/g, "_"), ...frames.reverse()].join(";");
  folded.set(path, (folded.get(path) ?? 0) + 1);
}
await Bun.write(out, [...folded].map(([k, v]) => `${k} ${v}`).join("\n") + "\n");
console.log(`samples=${n} kept=${kept} unique_stacks=${folded.size}`);
