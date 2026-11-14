#!/usr/bin/env bash
# Starts Loki, Tempo, Pyroscope, Alloy as plain processes (Linux or macOS), the spike backend and two recording tees.
# env: OUT (output dir), BIN (binary cache dir). Ports: faro tee 31347 -> alloy 12347; otlp tee 31319 -> alloy 4318.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
OUT=${OUT:-$ROOT/out}; BIN=${BIN:-$ROOT/.bin}; DATA=$OUT/data; LOGS=$OUT/logs
mkdir -p "$BIN" "$DATA" "$LOGS"
export DATA
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) os=linux; arch=amd64 ;;
  Darwin-arm64) os=darwin; arch=arm64 ;;
  *) echo "unsupported"; exit 1 ;;
esac
dl() { # url file
  [ -s "$BIN/$2" ] || curl -fsSL -o "$BIN/$2" "$1"
}
t0=$(date +%s)
dl https://github.com/grafana/loki/releases/download/v3.7.9/loki-$os-$arch.zip loki.zip
dl https://github.com/grafana/tempo/releases/download/v3.1.1/tempo_3.1.1_${os}_${arch}.tar.gz tempo.tgz
dl https://github.com/grafana/pyroscope/releases/download/v2.4.3/pyroscope_2.4.3_${os}_${arch}.tar.gz pyroscope.tgz
dl https://github.com/grafana/alloy/releases/download/v1.21.3/alloy-$os-$arch.zip alloy.zip
( cd "$BIN" && [ -x loki ] || { unzip -o -q loki.zip && mv loki-$os-$arch loki; } )
( cd "$BIN" && [ -x tempo ] || tar xzf tempo.tgz tempo )
( cd "$BIN" && [ -x pyroscope ] || tar xzf pyroscope.tgz pyroscope )
( cd "$BIN" && [ -x alloy ] || { unzip -o -q alloy.zip && mv alloy-$os-$arch alloy; } ); chmod +x "$BIN"/{loki,tempo,pyroscope,alloy}
echo "download+unpack s=$(( $(date +%s) - t0 ))"
nohup "$BIN/loki" -config.file="$HERE/loki.yaml" -config.expand-env=true > "$LOGS/loki.log" 2>&1 &
nohup "$BIN/tempo" -config.file="$HERE/tempo.yaml" -config.expand-env=true -backend-schedulerbackend-scheduler.local-work-path="$DATA/tempo/work" > "$LOGS/tempo.log" 2>&1 &
mkdir -p "$DATA/pyroscope"; ( cd "$DATA/pyroscope" && nohup "$BIN/pyroscope" -config.file="$HERE/pyroscope.yaml" -metastore.min-ready-duration=0 -storage.filesystem.dir=./data -architecture.storage=v2 -enable-query-backend-from=2020-01-01T00:00:00Z > "$LOGS/pyroscope.log" 2>&1 & )
nohup "$BIN/alloy" run --server.http.listen-addr=127.0.0.1:12345 --storage.path="$DATA/alloy" "$HERE/alloy.alloy" > "$LOGS/alloy.log" 2>&1 &
( cd "$ROOT/backend" && bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null; nohup bun server.ts > "$LOGS/backend.log" 2>&1 & )
nohup bun "$ROOT/tools/tee.ts" 31347 http://127.0.0.1:12347 "$OUT/faro-bodies.ndjson" --down-file "$OUT/COLLECTOR_DOWN" > "$LOGS/tee-faro.log" 2>&1 &
nohup bun "$ROOT/tools/tee.ts" 31319 http://127.0.0.1:4318 "$OUT/otlp-bodies.ndjson" > "$LOGS/tee-otlp.log" 2>&1 &
wait_ok() { for i in $(seq 1 90); do curl -fsS -o /dev/null "$1" 2>/dev/null && { echo "ready $1 after ${i}s"; return 0; }; sleep 1; done; echo "NOT READY $1"; return 1; }
wait_ok http://127.0.0.1:3100/ready
wait_ok http://127.0.0.1:3200/ready
wait_ok http://127.0.0.1:4040/ready
wait_ok http://127.0.0.1:12345/-/ready
wait_ok http://127.0.0.1:31380/health
echo "stack up s=$(( $(date +%s) - t0 ))"
