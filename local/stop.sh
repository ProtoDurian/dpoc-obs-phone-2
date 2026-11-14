#!/usr/bin/env bash
# Stop the local demo: Grafana container, and the stack processes found by their listening ports (by PID, never pkill -f).
docker rm -f diene-spike-obs-m-grafana > /dev/null 2>&1 && echo "grafana removed"
pids=$(ss -ltnpH 2>/dev/null | grep -E ':(3100|3200|4040|4318|4418|12345|12347|31380|31347|31319) ' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
for p in $pids; do [ "$p" != "$$" ] && kill "$p" 2>/dev/null && echo "killed $p ($(cat /proc/$p/comm 2>/dev/null))"; done
sleep 2
ss -ltnH | grep -E ':(3100|3200|4040|4318|12345|12347|31380|31347|31319) ' && echo "STILL LISTENING" || echo "all stopped"
