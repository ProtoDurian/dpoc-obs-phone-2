#!/usr/bin/env bash
# Local "Sentry-like in Grafana" demo from REAL phone data recorded in CI:
# start Loki/Tempo/Pyroscope/Alloy, replay the recorded Faro + OTLP bodies through Alloy (with the edge symbolizer),
# push every flame-graph source to Pyroscope, start Grafana with the two dashboards, screenshot them, stop everything.
# Run under the shared lock: flock /tmp/claude-1000/diene-heavy.lock bash local/demo.sh
# env: KEEP=1 leaves the stack + Grafana running (stop with local/stop.sh)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); PH=$(cd "$HERE/.." && pwd); M=$(cd "$PH/.." && pwd)
export OUT=$PH/out-replay BIN=$PH/.bin
SHOTS=$M/screenshots; mkdir -p "$SHOTS"
rm -rf "$OUT"; mkdir -p "$OUT"
t0=$(date +%s)
bash "$PH/stack/start.sh" > "$OUT/stack-start.txt" 2>&1 < /dev/null; tail -6 "$OUT/stack-start.txt"

# --- symbols by build id (Android release; iOS simulator stacks are symbolic debug stacks) ---
SYMS=$PH/out-replay/syms; mkdir -p "$SYMS"
for f in "$PH"/out-android*/android-out/app/build/sym/app.android-x64.symbols; do
  [ -f "$f" ] || continue
  bid=$(nix shell nixpkgs#binutils -c readelf -n "$f" | awk '/Build ID/{print $3}'); cp "$f" "$SYMS/$bid.symbols"
done
ls "$SYMS"
export LLVM_SYMBOLIZER=$(nix shell nixpkgs#llvm -c sh -c 'command -v llvm-symbolizer')
FARO=$(ls "$PH"/out-android*/android-out/out/faro-bodies.ndjson "$PH"/out-ios*/ios-out/out/faro-bodies.ndjson 2>/dev/null)
OTLP=$(ls "$PH"/out-android*/android-out/out/otlp-bodies.ndjson "$PH"/out-ios*/ios-out/out/otlp-bodies.ndjson 2>/dev/null)
echo "replay files:"; echo "$FARO"; echo "$OTLP"
SYMS=$SYMS bun "$PH/tools/replay.ts" $FARO $OTLP | tee "$OUT/replay.txt"

# --- flame-graph sources into Pyroscope ---
push() { [ -s "$1" ] && bun "$PH/tools/push-folded.ts" "$@" | tee -a "$OUT/pyroscope-push.txt"; }
for d in "$PH"/out-android*/android-out/out; do
  push "$d/raw/dartvm-profile.folded" spike-shop "source=dart_vm,platform=android,build_mode=profile" samples 1000
  push "$d/post/simpleperf-fp.folded" spike-shop "source=simpleperf_fp,platform=android,build_mode=release" samples 1000
  push "$d/post/simpleperf-dwarf.folded" spike-shop "source=simpleperf_dwarf,platform=android,build_mode=release" samples 1000
done
for d in "$PH"/out-ios*/ios-out/out; do
  push "$d/post/sample-ios.folded" spike-shop "source=macos_sample,platform=ios_sim,build_mode=debug" samples 1000
  push "$d/post/xctrace.folded" spike-shop "source=xctrace,platform=ios_sim,build_mode=debug" samples 1000
done
for f in $FARO; do
  plat=$(echo "$f" | grep -q out-ios && echo ios_sim || echo android)
  jq -r '.body | fromjson? | .events[]? | select(.name=="prof_folded") | .attributes.folded' "$f" > "$OUT/app-prof-$plat.folded"
  push "$OUT/app-prof-$plat.folded" spike-shop "source=app_instrumented,platform=$plat" microseconds
done
sleep 20  # let Loki/Tempo flush to queryable state

# --- Grafana ---
bun "$M/grafana/gen.ts" "$M/grafana/dash2"
docker rm -f diene-spike-obs-m-grafana > /dev/null 2>&1
docker run -d --name diene-spike-obs-m-grafana --network host \
  -v "$M/grafana/provisioning:/etc/grafana/provisioning:ro" -v "$M/grafana/dash2:/var/lib/grafana/dashboards:ro" \
  -e GF_SERVER_HTTP_PORT=33000 -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin -e GF_AUTH_DISABLE_LOGIN_FORM=true \
  -e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_NEWS_NEWS_FEED_ENABLED=false grafana/grafana:12.1.0 > /dev/null
for i in $(seq 1 60); do curl -fs http://127.0.0.1:33000/api/health > /dev/null && break; sleep 1; done
sleep 5
bash "$PH/ci/dump.sh" > "$OUT/dump.txt" 2>&1; head -30 "$OUT/dump.txt"
shot() { # uid file height
  google-chrome --headless=new --no-sandbox --disable-gpu --hide-scrollbars --window-size=1600,"$3" --virtual-time-budget=25000 \
    --screenshot="$SHOTS/$2" "http://127.0.0.1:33000/d/$1?orgId=1&kiosk&from=now-6h&to=now" > /dev/null 2>&1
  echo "shot $2 $(stat -c %s "$SHOTS/$2" 2>/dev/null)"
}
shot phone-errors phone-errors.png 3000
shot phone-slow phone-slow.png 5200
echo "demo s=$(( $(date +%s) - t0 ))"
[ "${KEEP:-0}" = 1 ] || bash "$HERE/stop.sh"
