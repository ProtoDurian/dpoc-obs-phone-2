// Convert macOS `sample` call-tree text into folded stacks (root;...;leaf selfcount).
// Lines look like: "    +   2385 start  (in dyld) + 1234  [0x18f...]" with depth given by indentation.
// usage: bun fold-sample.ts <sample.txt> <out.folded>
const [inp, out] = Bun.argv.slice(2);
const text = await Bun.file(inp).text();
const tree = text.split("Call graph:")[1]?.split(/\n\s*\n|Total number in stack/)[0] ?? "";
type N = { depth: number; name: string; count: number; children: N[] };
const root: N = { depth: -1, name: "root", count: 0, children: [] };
const stack: N[] = [root];
for (const line of tree.split("\n")) {
  const m = line.match(/^([\s+!:|]*)(\d+)\s+(.*)$/);
  if (!m) continue;
  const depth = m[1].length;
  let name = m[3].replace(/\s+\[0x[0-9a-f,]+\]\s*$/, "").replace(/\s+\+\s+\d+$/, "").trim();
  name = name.replace(/\s+\(in ([^)]+)\)/, "[$1]").replace(/[; ]/g, "_");
  const node: N = { depth, name, count: Number(m[2]), children: [] };
  while (stack.length > 1 && stack[stack.length - 1].depth >= depth) stack.pop();
  stack[stack.length - 1].children.push(node);
  stack.push(node);
}
const lines: string[] = [];
const walk = (n: N, path: string[]) => {
  const p = n === root ? [] : [...path, n.name];
  const childSum = n.children.reduce((a, c) => a + c.count, 0);
  if (n !== root && n.count - childSum > 0) lines.push(`${p.join(";")} ${n.count - childSum}`);
  for (const c of n.children) walk(c, p);
};
walk(root, []);
await Bun.write(out, lines.join("\n") + "\n");
console.log(`folded_lines=${lines.length} total=${root.children.reduce((a, c) => a + c.count, 0)}`);
