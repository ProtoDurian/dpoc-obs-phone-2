// Per-run numbers from recorded Faro bodies: start-up, screens, frames, errors, sampling, offline replays.
// usage: bun analyse.ts <faro-bodies.ndjson> <out.json>
const [file, outFile] = Bun.argv.slice(2);
type Run = Record<string, any>;
const runs = new Map<string, Run>();
const exByKey = new Map<string, { n: number; sends: number[] }>();
const lines = (await Bun.file(file).text()).split("\n").filter(Boolean);
let down = 0, bodies = 0;
const sessionsByRun = new Map<string, Set<string>>();
for (const l of lines) {
  const r = JSON.parse(l);
  if (r.down) { down++; continue; }
  let b: any; try { b = JSON.parse(r.body); } catch { continue; }
  bodies++;
  const a = b.meta?.session?.attributes ?? {};
  const id = a.run_id ?? "?";
  const run = runs.get(id) ?? { run: id, platform: a.client_kind, build: a.build_mode, device: `${a.device_model ?? ""} ${a.device_os ?? ""} ${a.device_os_version ?? ""}`.trim(), bodies: 0 };
  run.bodies++; runs.set(id, run);
  (sessionsByRun.get(id) ?? sessionsByRun.set(id, new Set()).get(id)!).add(b.meta?.session?.id);
  for (const m of b.measurements ?? []) {
    if (m.type === "app_start_spike") {
      const v = m.values;
      run.start = { ...v, process_to_main_true_ms: v.process_to_first_frame_ms != null ? +(v.process_to_first_frame_ms - v.main_to_first_frame_ms).toFixed(1) : null };
    }
    if (m.type === "app_startup") (run.faro_startup ??= []).push(m.values);
    if (m.type === "frames") run.frames = m.values;
  }
  for (const e of b.events ?? []) {
    if (e.name === "screen_ready") (run.screens ??= []).push({ screen: e.attributes.screen, total: +e.attributes.total_ms, network: +e.attributes.network_ms, render: +e.attributes.render_ms });
    if (e.name === "slow_frame") run.slow_frames = (run.slow_frames ?? 0) + 1;
  }
  for (const x of b.exceptions ?? []) {
    const k = `${x.type}|${x.timestamp}|${(x.value ?? "").slice(0, 60)}`;
    const g = exByKey.get(k) ?? { n: 0, sends: [] };
    g.n++; g.sends.push(r.ts); exByKey.set(k, g);
    (run.errors ??= []).push(`${x.type}: ${(x.value ?? "").slice(0, 70)}`);
  }
}
const pct = (xs: number[], p: number) => { const s = [...xs].sort((a, b) => a - b); return s.length ? +s[Math.min(s.length - 1, Math.floor(p * s.length))].toFixed(0) : null; };
const cold = [...runs.values()].filter((r) => /^(cold|sample|after|prof-cold)-/.test(r.run) && r.start);
const by = (pred: (r: Run) => boolean, f: (r: Run) => number) => cold.filter(pred).map(f).filter((x) => Number.isFinite(x));
const summary: any = { bodies, down_503: down, runs: runs.size };
for (const build of ["release", "profile", "debug"]) {
  const pr = (r: Run) => r.build === build;
  const n = cold.filter(pr).length; if (!n) continue;
  summary[`cold_${build}`] = {
    n,
    process_to_first_frame_ms: { p50: pct(by(pr, (r) => r.start.process_to_first_frame_ms), 0.5), p90: pct(by(pr, (r) => r.start.process_to_first_frame_ms), 0.9) },
    process_to_main_ms: { p50: pct(by(pr, (r) => r.start.process_to_main_true_ms), 0.5) },
    main_to_first_frame_ms: { p50: pct(by(pr, (r) => r.start.main_to_first_frame_ms), 0.5) },
    faro_init_ms: { p50: pct(by(pr, (r) => r.start.obs_init_ms), 0.5) },
    home_ready_ms: { p50: pct(by(pr, (r) => r.start.home_ready_ms), 0.5) },
    process_to_usable_ms: { p50: pct(by(pr, (r) => r.start.process_to_usable_ms), 0.5), p90: pct(by(pr, (r) => r.start.process_to_usable_ms), 0.9) },
    faro_appStartDuration_ms: { p50: pct(cold.filter(pr).flatMap((r) => (r.faro_startup ?? []).filter((s: any) => s.coldStart === 1).map((s: any) => s.appStartDuration)), 0.5) },
  };
}
const warm = [...runs.values()].flatMap((r) => (r.faro_startup ?? []).filter((s: any) => s.coldStart === 0).map((s: any) => s.appStartDuration));
summary.faro_warm_appStartDuration_ms = warm;
const screens = [...runs.values()].flatMap((r) => r.screens ?? []);
for (const s of [...new Set(screens.map((x) => x.screen))]) {
  const xs = screens.filter((x) => x.screen === s);
  summary[`screen_${s}`] = { n: xs.length, total_p50: pct(xs.map((x) => x.total), 0.5), network_p50: pct(xs.map((x) => x.network), 0.5), render_p50: pct(xs.map((x) => x.render), 0.5) };
}
summary.exceptions_unique = exByKey.size;
summary.exceptions_sent = [...exByKey.values()].reduce((a, g) => a + g.n, 0);
summary.exceptions_resent = [...exByKey].filter(([, g]) => g.n > 1).map(([k, g]) => ({ key: k.slice(0, 100), times_sent: g.n }));
const sampleRuns = [...runs.keys()].filter((k) => k.startsWith("sample-"));
summary.sampling = { launched: "see steps log", runs_with_any_body: sampleRuns.sort() };
summary.sessions_per_run_max = Math.max(...[...sessionsByRun.values()].map((s) => s.size));
await Bun.write(outFile, JSON.stringify({ summary, runs: [...runs.values()] }, null, 1));
console.log(JSON.stringify(summary, null, 1));
