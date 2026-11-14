#!/usr/bin/env bash
# Host side, after the emulator: decode stacks, turn every profile into folded stacks, push to Pyroscope,
# query the Perfetto traces, then dump what arrived in the stores.
# env: OUT, ROOT, SYM, ENGINE (flutter engine revision)
set -uo pipefail
R=$OUT/raw; P=$OUT/post; mkdir -p "$P"
log() { echo "[post $(date +%H:%M:%S)] $*" | tee -a "$P/steps.txt"; }
SP=$(ls -d "$ANDROID_NDK_HOME"/simpleperf/bin/linux/x86_64/simpleperf 2>/dev/null || ls -d "$ANDROID_SDK_ROOT"/ndk/*/simpleperf/bin/linux/x86_64/simpleperf | tail -1)
log "simpleperf host: $SP"

# --- Dart symbols for simpleperf: the split-debug-info ELF has the same build id as libapp.so ---
mkdir -p "$P/symdir"; cp "$SYM"/app.android-x64.symbols "$P/symdir/libapp.so"
file "$SYM"/app.android-x64.symbols > "$P/symbols-file.txt" 2>&1; readelf -n "$SYM"/app.android-x64.symbols >> "$P/symbols-file.txt" 2>&1
# Flutter engine symbols (public, by engine revision)
curl -fsSL -o "$P/engine-symbols.zip" "https://storage.googleapis.com/flutter_infra_release/flutter/$ENGINE/android-x64-release/symbols.zip" && (cd "$P/symdir" && unzip -o -q ../engine-symbols.zip) ; ls -la "$P/symdir" > "$P/symdir-list.txt"
for cg in fp dwarf; do
  [ -s "$R/perf-$cg.data" ] || { log "no perf-$cg.data"; continue; }
  "$SP" report -i "$R/perf-$cg.data" --symdir "$P/symdir" --sort dso > "$P/simpleperf-$cg-dso.txt" 2>&1
  "$SP" report -i "$R/perf-$cg.data" --symdir "$P/symdir" --sort symbol --dsos "$(grep -o '[^ ]*libapp.so' "$P/simpleperf-$cg-dso.txt" | head -1)" > "$P/simpleperf-$cg-libapp-symbols.txt" 2>&1
  "$SP" report-sample -i "$R/perf-$cg.data" --symdir "$P/symdir" --show-callchain > "$P/simpleperf-$cg-samples.txt" 2>&1
  bun "$ROOT/tools/fold-simpleperf.ts" "$P/simpleperf-$cg-samples.txt" "$P/simpleperf-$cg.folded" | tee -a "$P/steps.txt"
  bun "$ROOT/tools/fold-simpleperf.ts" "$P/simpleperf-$cg-samples.txt" "$P/simpleperf-$cg-ui.folded" '^(1\.ui|main|spike_shop|cloud\.atomi)' | tee -a "$P/steps.txt"
  bun "$ROOT/tools/push-folded.ts" "$P/simpleperf-$cg.folded" spike-shop "source=simpleperf_$cg,platform=android,build_mode=release" samples 1000 | tee -a "$P/steps.txt"
done

# --- Dart VM profile (profile build) ---
[ -s "$R/dartvm-profile.folded" ] && bun "$ROOT/tools/push-folded.ts" "$R/dartvm-profile.folded" spike-shop "source=dart_vm,platform=android,build_mode=profile" samples 1000 | tee -a "$P/steps.txt"

# --- instrumented prof_folded events from the app (release) ---
jq -r '.body | fromjson? | .events[]? | select(.name=="prof_folded") | .attributes.folded' "$OUT/faro-bodies.ndjson" > "$P/app-prof.folded" 2>/dev/null
[ -s "$P/app-prof.folded" ] && bun "$ROOT/tools/push-folded.ts" "$P/app-prof.folded" spike-shop "source=app_instrumented,platform=android,build_mode=release" microseconds | tee -a "$P/steps.txt"

# --- Perfetto: which Flutter slices exist in release vs profile ---
curl -fsSL -o "$P/perfetto.zip" https://github.com/google/perfetto/releases/download/v59.1/linux-amd64.zip && (cd "$P" && unzip -o -q perfetto.zip)
TP=$(find "$P" -name trace_processor_shell -type f | head -1); chmod +x "$TP" 2>/dev/null
for m in release profile; do
  [ -s "$R/perfetto-$m.pftrace" ] || continue
  cat > "$P/q.sql" <<'SQL'
select t.name as thread, s.name as slice, count(*) as n, round(sum(s.dur)/1e6,1) as ms
from slice s join thread_track tt on s.track_id = tt.id join thread t using(utid) join process p using(upid)
where p.name like '%spike_shop%' group by 1,2 order by ms desc limit 40;
SQL
  "$TP" -q "$P/q.sql" "$R/perfetto-$m.pftrace" > "$P/perfetto-$m-slices.txt" 2>&1
  log "perfetto $m: $(grep -c . "$P/perfetto-$m-slices.txt") lines; flutter-ish: $(grep -ciE 'animator|rasterizer|frame|flutter|build' "$P/perfetto-$m-slices.txt")"
done

# --- errors: extract and decode obfuscated Dart stacks ---
bun "$ROOT/tools/extract-errors.ts" "$OUT/faro-bodies.ndjson" "$P/errors" | tee -a "$P/steps.txt"
BID=$(readelf -n "$SYM"/app.android-x64.symbols | awk '/Build ID/{print $3}'); mkdir -p "$P/syms"; cp "$SYM"/app.android-x64.symbols "$P/syms/$BID.symbols"
export LLVM_SYMBOLIZER=$(ls "$ANDROID_SDK_ROOT"/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-symbolizer | tail -1)
for f in "$P"/errors/err-*.txt; do
  if grep -q 'build_id' "$f"; then
    flutter symbolize -i "$f" -d "$SYM"/app.android-x64.symbols > "${f%.txt}.flutter-symbolize.txt" 2>&1 || true
    bun "$ROOT/tools/symbolize.ts" "$P/syms" "$f" > "${f%.txt}.decoded.txt" 2>&1 || true
    log "decoded $(basename $f): $(head -1 "${f%.txt}.decoded.txt")"
  fi
done
ls "$P/errors" | head -50 > "$P/errors-list.txt"

# --- stores ---
bash "$ROOT/ci/dump.sh" | tee "$P/dump.txt"
