// Convert `simpleperf report-sample --show-callchain` text (simpleperf in NDK 27: YAML-like blocks) to folded stacks.
// Block: "sample:" then "  thread_name:", the leaf "  file:/  symbol:", then "  callchain:" with "    symbol:/    file:"
// entries from the leaf's caller up to the root. With --symdir holding the split-debug-info file renamed to
// libapp.so, Dart AOT frames already come out with real (de-obfuscated) names.
// usage: bun fold-simpleperf.ts <in.txt> <out.folded> [threadFilter regex]
const [inp, out, thr] = Bun.argv.slice(2);
const text = await Bun.file(inp).text();
const re = thr ? new RegExp(thr) : null;
const folded = new Map<string, number>();
let n = 0, kept = 0;
const short = (sym: string, file: string) => {
  const dso = file.split("/").pop()!.replace(/!.*$/, "");
  const s = !sym || sym.startsWith("*") || /^[0-9a-f]+$/.test(sym) ? "?" : sym;
  return `${s} [${dso}]`.replace(/;/g, ":");
};
for (const block of text.split(/^sample:\s*$/m).slice(1)) {
  const tname = block.match(/^\s+thread_name:\s*(.*)$/m)?.[1]?.trim() ?? "?";
  const [head, chain = ""] = block.split(/^\s+callchain:\s*$/m);
  const leafFile = head.match(/^  file:\s*(.*)$/m)?.[1] ?? "";
  const leafSym = head.match(/^  symbol:\s*(.*)$/m)?.[1] ?? "";
  const frames = [short(leafSym, leafFile)];
  let file = "", sym = "";
  for (const line of chain.split("\n")) {
    const f = line.match(/^\s{4}file:\s*(.*)$/); const s = line.match(/^\s{4}symbol:\s*(.*)$/);
    if (f) file = f[1];
    if (s) sym = s[1];
    if (f || s) { if (file && sym) { frames.push(short(sym, file)); file = ""; sym = ""; } }
  }
  n++;
  if (re && !re.test(tname)) continue;
  kept++;
  const path = [tname.replace(/;/g, ":"), ...frames.reverse()].join(";");
  folded.set(path, (folded.get(path) ?? 0) + 1);
}
await Bun.write(out, [...folded].map(([k, v]) => `${k} ${v}`).join("\n") + "\n");
console.log(`samples=${n} kept=${kept} unique_stacks=${folded.size}`);
