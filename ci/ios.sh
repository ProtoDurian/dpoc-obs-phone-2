#!/usr/bin/env bash
# macOS runner: build the app for the iOS Simulator, run cold/warm starts, error/crash/hang scenarios,
# sample the process for a flame graph, then dump what arrived. env: OUT, ROOT
set -uo pipefail
R=$OUT/raw; P=$OUT/post; mkdir -p "$R" "$P"
BID=cloud.atomi.spike.spikeShop
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$R/ios-steps.txt"; }
{ sw_vers; sysctl -n machdep.cpu.brand_string; sysctl -n hw.ncpu; xcodebuild -version; } > "$R/mac-facts.txt" 2>&1
log "mac: $(tr '\n' ' ' < "$R/mac-facts.txt")"
cd "$ROOT/app"
flutter pub get > /dev/null

# --- which build modes can run on the Simulator? ---
for mode in release profile debug; do
  s=$(date +%s)
  if [ $mode = release ]; then mkdir -p build/sym; extra="--obfuscate --split-debug-info=build/sym --extra-gen-snapshot-options=--save-obfuscation-map=build/sym/obfuscation-map.json"; else extra=""; fi
  flutter build ios --simulator --$mode $extra --build-name 1.2.0 --build-number 12 > "$R/build-sim-$mode.txt" 2>&1; rc=$?
  log "build ios --simulator --$mode rc=$rc s=$(( $(date +%s) - s )) :: $(tail -2 "$R/build-sim-$mode.txt" | tr '\n' ' ' | cut -c1-200)"
  if [ $rc = 0 ]; then SIM_MODE=$mode; break; fi
done
APP=$(ls -d build/ios/iphonesimulator/Runner.app 2>/dev/null)
# device release build (no signing): what a store build carries (obfuscated, split symbols, dSYMs)
s=$(date +%s)
mkdir -p build/sym-device; flutter build ios --release --no-codesign --obfuscate --split-debug-info=build/sym-device --extra-gen-snapshot-options=--save-obfuscation-map=build/sym-device/obfuscation-map.json --build-name 1.2.0 --build-number 12 > "$R/build-device-release.txt" 2>&1
log "build ios --release --no-codesign rc=$? s=$(( $(date +%s) - s ))"
{ ls -la build/sym-device build/sym 2>/dev/null; find build/ios -name '*.dSYM' -maxdepth 4; du -sh build/ios/iphoneos/Runner.app 2>/dev/null; } > "$R/ios-build-artifacts.txt" 2>&1

# --- simulator ---
UDID=$(xcrun simctl list devices available -j | jq -r '[.devices | to_entries[] | select(.key|test("iOS")) | .value[] | select(.name|test("^iPhone"))][0].udid')
NAME=$(xcrun simctl list devices available -j | jq -r --arg u "$UDID" '.devices[][] | select(.udid==$u) | .name')
s=$(date +%s); xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1
log "simulator $NAME $UDID booted in $(( $(date +%s) - s )) s; mode=$SIM_MODE"
xcrun simctl install "$UDID" "$APP"; log "installed $APP"
export SIMCTL_CHILD_SPIKE_API=http://127.0.0.1:31380 SIMCTL_CHILD_SPIKE_COLLECTOR=http://127.0.0.1:31347/collect
launch() { # run scenario [rate]
  local run=$1 sc=$2
  SIMCTL_CHILD_SPIKE_SCENARIO=$sc SIMCTL_CHILD_SPIKE_RUN=$run SIMCTL_CHILD_SPIKE_USER="u-$((RANDOM % 7))" SIMCTL_CHILD_SPIKE_RATE=${3:-1.0} \
    xcrun simctl launch --terminate-running-process --stdout="$R/stdout-$run.txt" --stderr="$R/stderr-$run.txt" "$UDID" $BID > "$R/launch-$run.txt" 2>&1
  log "launch $run $sc: $(cat "$R/launch-$run.txt" | tr '\n' ' ')"
}
wait_mark() { for i in $(seq 1 "$3"); do grep -q "$2" "$R/stdout-$1.txt" 2>/dev/null && return 0; sleep 1; done; return 1; }
for i in 1 2 3 4 5 6; do xcrun simctl terminate "$UDID" $BID 2>/dev/null; sleep 1; launch "cold-$i" normal; wait_mark "cold-$i" "MMARK done" 60 || log "cold-$i no done"; sleep 2; done
# warm: switch to Settings and back (process stays alive)
for i in 1 2 3; do xcrun simctl launch "$UDID" com.apple.Preferences > /dev/null 2>&1; sleep 2; xcrun simctl launch "$UDID" $BID >> "$R/launch-warm.txt" 2>&1; sleep 4; done
for sc in dart_uncaught result_error hang_dart hang_native; do
  xcrun simctl terminate "$UDID" $BID 2>/dev/null; sleep 1; launch "$sc-1" $sc; wait_mark "$sc-1" "MMARK done" 90; sleep 6
done
xcrun simctl terminate "$UDID" $BID 2>/dev/null; sleep 1; launch native_crash-1 native_crash; sleep 10
ls -t ~/Library/Logs/DiagnosticReports/ 2>/dev/null | head -5 > "$R/diagnostic-reports.txt"; cp "$(ls -t ~/Library/Logs/DiagnosticReports/Runner* 2>/dev/null | head -1)" "$R/" 2>/dev/null || true
launch after-crash-1 normal; wait_mark after-crash-1 "MMARK done" 60; sleep 8
for i in 1 2 3 4 5 6; do xcrun simctl terminate "$UDID" $BID 2>/dev/null; sleep 1; launch "sample-$i" normal 0.5; wait_mark "sample-$i" "MMARK done" 60; sleep 2; done
curl -s http://127.0.0.1:31380/_seen > "$R/backend-seen.json"

# --- flame graph routes on the Simulator: `sample` (system sampler) and xctrace Time Profiler ---
xcrun simctl terminate "$UDID" $BID 2>/dev/null; sleep 1; launch sampler-1 normal
pid=$(grep -o '[0-9]*$' "$R/launch-sampler-1.txt" | tail -1)
sample "$pid" 8 1 -file "$R/sample-sampler-1.txt" > /dev/null 2>&1; log "sample pid=$pid lines=$(wc -l < "$R/sample-sampler-1.txt" 2>/dev/null)"
bun "$ROOT/tools/fold-sample.ts" "$R/sample-sampler-1.txt" "$P/sample-ios.folded" | tee -a "$R/ios-steps.txt"
bun "$ROOT/tools/push-folded.ts" "$P/sample-ios.folded" spike-shop "source=macos_sample,platform=ios_sim,build_mode=$SIM_MODE" samples 1000 | tee -a "$R/ios-steps.txt"
xcrun simctl terminate "$UDID" $BID 2>/dev/null; sleep 1; launch xctrace-1 normal
pid=$(grep -o '[0-9]*$' "$R/launch-xctrace-1.txt" | tail -1)
xcrun xctrace record --template 'Time Profiler' --device "$UDID" --attach "$pid" --time-limit 8s --output "$R/xctrace.trace" > "$R/xctrace-record.txt" 2>&1; log "xctrace rc=$? $(tail -1 "$R/xctrace-record.txt")"
xcrun xctrace export --input "$R/xctrace.trace" --toc > "$R/xctrace-toc.xml" 2>&1
xcrun xctrace export --input "$R/xctrace.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$P/xctrace-time-profile.xml" 2>&1
log "xctrace export bytes=$(wc -c < "$P/xctrace-time-profile.xml")"
xcrun simctl spawn "$UDID" log show --last 15m --predicate 'process == "Runner"' --style compact > "$R/sim-os-log.txt" 2>&1 || true

# --- post: errors, instrumented profile, dumps ---
jq -r '.body | fromjson? | .events[]? | select(.name=="prof_folded") | .attributes.folded' "$OUT/faro-bodies.ndjson" > "$P/app-prof.folded" 2>/dev/null
[ -s "$P/app-prof.folded" ] && bun "$ROOT/tools/push-folded.ts" "$P/app-prof.folded" spike-shop "source=app_instrumented,platform=ios_sim,build_mode=$SIM_MODE" microseconds | tee -a "$R/ios-steps.txt"
bun "$ROOT/tools/extract-errors.ts" "$OUT/faro-bodies.ndjson" "$P/errors" | tee -a "$R/ios-steps.txt"
for f in "$P"/errors/err-*.txt; do
  grep -q '_kDartIsolateSnapshotInstructions\|build_id' "$f" && flutter symbolize -i "$f" -d build/sym/app.ios-arm64.symbols > "${f%.txt}.decoded.txt" 2>&1
done
bash "$ROOT/ci/dump.sh" | tee "$P/dump.txt"
log "ios.sh done"
