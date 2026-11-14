#!/usr/bin/env bash
# Stop the local demo: Grafana container, and the stack processes found by their listening ports (by PID, never pkill -f).
# Tempo and Pyroscope can hang in graceful shutdown: SIGKILL after 10 s.
docker rm -f diene-spike-obs-m-grafana > /dev/null 2>&1 && echo "grafana removed"
PORTS=':(3100|3200|4040|4318|4418|12345|12347|31380|31347|31319) '
pids() { ss -ltnpH 2>/dev/null | grep -E "$PORTS" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }
for p in $(pids); do kill "$p" 2>/dev/null && echo "TERM $p ($(cat /proc/$p/comm 2>/dev/null))"; done
for i in $(seq 1 10); do [ -z "$(pids)" ] && break; sleep 1; done
for p in $(pids); do kill -9 "$p" 2>/dev/null && echo "KILL $p ($(cat /proc/$p/comm 2>/dev/null))"; done
sleep 1; [ -z "$(pids)" ] && echo "all stopped" || echo "STILL LISTENING"
