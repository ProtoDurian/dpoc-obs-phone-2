// Edge symbolizer for obfuscated Flutter release stacks (--obfuscate --split-debug-info).
// A release Dart stack is "non-symbolic": build_id + virtual addresses. The split-debug-info file is an ELF
// with DWARF and the same build id, so stock llvm-symbolizer turns each address into function + file:line.
// (flutter symbolize 3.47.4 fails on these: "Cannot locate isolate instructions section in snapshot".)
// Symbols are looked up by build id: <symDir>/<build_id>.symbols (copy app.<abi>.symbols there at build time).
// Grouping key (Sentry-like): sha1(type | top 5 in-app function names, no line numbers).
//
// CLI: bun symbolize.ts <symDir> <stack.txt> [type]   -> prints decoded frames + group key
import { createHash } from "node:crypto";

export type Frame = { fn: string; file: string; line: number; inApp: boolean };
export type Decoded = { buildId: string; frames: Frame[]; group: string; top: string; ok: boolean; why?: string };

const SYMBOLIZER = process.env.LLVM_SYMBOLIZER ?? "llvm-symbolizer";
const IN_APP = new RegExp(process.env.IN_APP ?? "/app/lib/");
const SKIP = new RegExp(process.env.GROUP_SKIP ?? "^new Failure$"); // error-wrapper frames that would make every Result error one group

export function parse(stack: string): { buildId: string; addrs: string[] } {
  const buildId = stack.match(/build_id: '([0-9a-f]+)'/)?.[1] ?? "";
  const addrs = [...stack.matchAll(/#\d+\s+abs\s+[0-9a-f]+\s+virt\s+([0-9a-f]+)/g)].map((m) => "0x" + m[1]);
  return { buildId, addrs };
}

export function groupKey(type: string, frames: Frame[]): { group: string; top: string } {
  const inApp = frames.filter((f) => f.inApp && !SKIP.test(f.fn)).slice(0, 5).map((f) => `${f.file.split("/").pop()}:${f.fn}`);
  const top = inApp[0] ?? frames[0]?.fn ?? "?";
  return { group: createHash("sha1").update([type, ...inApp].join("|")).digest("hex").slice(0, 12), top };
}

export async function decode(stack: string, symDir: string, type = ""): Promise<Decoded> {
  const { buildId, addrs } = parse(stack);
  if (!buildId || addrs.length === 0) return { buildId, frames: [], ...groupKey(type, []), ok: false, why: "no build_id/virt frames" };
  const obj = `${symDir}/${buildId}.symbols`;
  if (!(await Bun.file(obj).exists())) return { buildId, frames: [], ...groupKey(type, []), ok: false, why: `no symbols for ${buildId}` };
  const p = Bun.spawn([SYMBOLIZER, `--obj=${obj}`, "--output-style=JSON", "-f", "-C", "-i", ...addrs], { stdout: "pipe", stderr: "pipe" });
  const out = await new Response(p.stdout).text();
  await p.exited;
  const frames: Frame[] = [];
  type R = { Symbol?: { FunctionName: string; FileName: string; Line: number }[] };
  const rows: R[] = out.trim().startsWith("[") ? JSON.parse(out) : out.split("\n").filter(Boolean).map((l) => JSON.parse(l));
  for (const r of rows) {
    for (const s of r.Symbol ?? []) {
      if (!s.FunctionName) continue;
      frames.push({ fn: s.FunctionName, file: s.FileName, line: s.Line, inApp: IN_APP.test(s.FileName) });
    }
  }
  return { buildId, frames, ...groupKey(type, frames), ok: frames.length > 0 };
}

export const render = (d: Decoded) =>
  d.frames.map((f, i) => `#${String(i).padStart(2, "0")} ${f.fn} (${f.file.replace(/.*\/app\//, "")}:${f.line})${f.inApp ? "" : " [lib]"}`).join("\n");

if (import.meta.main) {
  const [symDir, file, type = ""] = Bun.argv.slice(2);
  const d = await decode(await Bun.file(file).text(), symDir, type);
  console.log(`build_id=${d.buildId} ok=${d.ok} group=${d.group} top=${d.top}${d.why ? " why=" + d.why : ""}`);
  console.log(render(d));
}
