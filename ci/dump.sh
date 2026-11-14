#!/usr/bin/env bash
# Dump what arrived in the stores (proof): Loki lines, Tempo traces, Pyroscope apps, Alloy faro counters.
set -uo pipefail
OUT=${OUT:?}; D=$OUT/arrived; mkdir -p "$D/traces"
now=$(date +%s); start=$(( now - 4*3600 ))
# counts per kind (metric query: small reply), then the lines of the rare kinds and a sample of the rest
curl -sG http://127.0.0.1:3100/loki/api/v1/query --data-urlencode 'query=sum by (kind) (count_over_time({app_name="spike-shop"}[4h]))' > "$D/loki-counts.json"
echo "loki lines by kind:"; jq -r '.data.result[]? | "\(.metric.kind)\t\(.value[1])"' "$D/loki-counts.json"
: > "$D/loki-lines.tsv"
for k in exception log measurement event; do
  curl -sG http://127.0.0.1:3100/loki/api/v1/query_range --data-urlencode "query={app_name=\"spike-shop\", kind=\"$k\"}" --data-urlencode "start=${start}000000000" --data-urlencode "end=${now}000000000" --data-urlencode limit=400 --data-urlencode direction=backward > "$D/loki-$k.json"
  jq -r '.data.result[]? | .stream.kind as $k | .values[] | "\($k)\t\(.[1])"' "$D/loki-$k.json" >> "$D/loki-lines.tsv"
done
echo "loki sample lines saved: $(wc -l < "$D/loki-lines.tsv")"
curl -sG http://127.0.0.1:3200/api/search --data-urlencode 'q={}' --data-urlencode limit=500 --data-urlencode "start=$start" --data-urlencode "end=$now" > "$D/tempo-search.json"
n=0; ids=$( { jq -r '.traces[]?.traceID' "$D/tempo-search.json"; jq -r '.body | fromjson? | .traces?.resourceSpans[]?.scopeSpans[]?.spans[]?.traceId' "$OUT/faro-bodies.ndjson" 2>/dev/null; } | sort -u | head -400)
for id in $ids; do curl -s "http://127.0.0.1:3200/api/v2/traces/$id" > "$D/traces/$id.json"; n=$((n+1)); done
echo "tempo traces: $n"; jq -r '.traces[]? | "\(.rootServiceName)\t\(.rootTraceName)"' "$D/tempo-search.json" | sort | uniq -c
curl -s http://127.0.0.1:4040/querier.v1.QuerierService/LabelValues -H 'content-type: application/json' -d "{\"name\":\"service_name\",\"start\":${start}000,\"end\":${now}000}" > "$D/pyroscope-services.json"; echo "pyroscope: $(cat "$D/pyroscope-services.json")"
curl -s http://127.0.0.1:12345/metrics | grep -E '^faro_receiver_' > "$D/alloy-faro-metrics.txt"; grep -c . "$D/alloy-faro-metrics.txt"
echo "faro bodies recorded: $(wc -l < "$OUT/faro-bodies.ndjson" 2>/dev/null), otlp bodies: $(wc -l < "$OUT/otlp-bodies.ndjson" 2>/dev/null)"
