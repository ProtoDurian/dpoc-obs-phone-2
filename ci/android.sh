#!/usr/bin/env bash
# Runs inside the booted Android emulator (GitHub Linux runner, KVM). Drives the spike app through
# cold/warm starts, error/crash/hang scenarios, offline buffering, sampling, and every flame-graph route.
# env: OUT, ROOT, APK_REL (obfuscated release), APK_PROF (profile), SYM (split-debug-info dir)
set -uo pipefail
PKG=cloud.atomi.spike.spike_shop
ACT=$PKG/.MainActivity
R=$OUT/raw; mkdir -p "$R"
API=http://10.0.2.2:31380; COL=http://10.0.2.2:31347/collect
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$R/android-steps.txt"; }

adb shell getprop ro.build.version.release > "$R/device.txt"; adb shell getprop ro.product.model >> "$R/device.txt"; adb shell getprop ro.product.cpu.abi >> "$R/device.txt"
log "device: $(tr '\n' ' ' < "$R/device.txt")"

wait_mark() { # pattern timeout_s
  for i in $(seq 1 "$2"); do adb logcat -d -s flutter:I 2>/dev/null | grep -q "$1" && return 0; sleep 1; done; return 1
}
launch() { # run_id scenario [extra am args...]
  local run=$1 sc=$2; shift 2
  adb logcat -c
  adb shell am start -W -n $ACT --es scenario "$sc" --es run "$run" --es api $API --es collector $COL --es user "u-$((RANDOM % 7))" "$@" > "$R/am-$run.txt" 2>&1
  log "launch $run $sc: $(grep -E 'LaunchState|TotalTime|WaitTime' "$R/am-$run.txt" | tr -s ' \n' ' ')"
}
save() { adb logcat -d > "$R/logcat-$1.txt"; grep MMARK "$R/logcat-$1.txt" | sed 's/.*MMARK/MMARK/' > "$R/marks-$1.txt"; }

# ---------------- release build (obfuscated, split-debug-info) ----------------
adb install -r "$APK_REL" > "$R/install-release.txt" 2>&1; log "installed release: $(tail -1 "$R/install-release.txt")"

# 1. cold starts
for i in 1 2 3 4 5 6 7 8; do
  adb shell am force-stop $PKG; sleep 1
  launch "cold-$i" normal
  wait_mark "MMARK done" 60 || log "cold-$i: no done mark"
  sleep 2; save "cold-$i"
done
# 2. warm (hot) starts: HOME then relaunch the same activity
for i in 1 2 3 4; do
  adb shell input keyevent KEYCODE_HOME; sleep 2
  adb shell am start -W -n $ACT > "$R/am-warm-$i.txt" 2>&1
  log "warm-$i: $(grep -E 'LaunchState|TotalTime' "$R/am-warm-$i.txt" | tr -s ' \n' ' ')"
  sleep 3
done
save warm

# 3. errors
for sc in dart_uncaught result_error; do
  adb shell am force-stop $PKG; sleep 1
  launch "$sc-1" $sc
  wait_mark "MMARK done" 60; sleep 3; save "$sc-1"
done
# 4. hangs (Faro ANR watchdog polls every 5 s; our watchdog reports on resume)
for sc in hang_dart hang_native; do
  adb shell am force-stop $PKG; sleep 1
  launch "$sc-1" $sc
  sleep 4; adb shell input tap 300 600; adb shell input tap 300 700   # user taps during the hang (system ANR needs input)
  wait_mark "MMARK done" 90; sleep 12; save "$sc-1"
  adb shell dumpsys activity anr > "$R/anr-dumpsys-$sc.txt" 2>&1 || true
done
# 5. native crash, then a normal launch that reports it (Faro reads ApplicationExitInfo on next start)
adb shell am force-stop $PKG; sleep 1
launch native_crash-1 native_crash
sleep 10; save native_crash-1
adb shell dumpsys activity exit-info $PKG > "$R/exit-info.txt" 2>&1 || true
launch after-crash-1 normal
wait_mark "MMARK done" 60; sleep 8; save after-crash-1

# 6. offline buffering: device offline during a session, then online again
adb shell am force-stop $PKG; sleep 1
adb shell svc wifi disable; adb shell svc data disable; sleep 3
log "offline: $(adb shell dumpsys connectivity | grep -m1 -i 'Active default network' )"
launch offline-1 normal
sleep 20; save offline-1-during
adb shell svc wifi enable; adb shell svc data enable
sleep 25; save offline-1-after
log "offline: bodies after reconnect: $(grep -c '"offline-1"' "$OUT/faro-bodies.ndjson" || true)"
# 6b. collector down while the device is online (tee answers 503), then up
adb shell am force-stop $PKG; sleep 1
touch "$OUT/COLLECTOR_DOWN"; launch down-1 normal; wait_mark "MMARK done" 60; sleep 4; save down-1
rm -f "$OUT/COLLECTOR_DOWN"
adb shell am force-stop $PKG; sleep 1; launch after-down-1 normal; wait_mark "MMARK done" 60; sleep 6; save after-down-1

# 7. session sampling 50 % (S7 traps on phones)
for i in 1 2 3 4 5 6 7 8; do
  adb shell am force-stop $PKG; sleep 1
  launch "sample-$i" normal --es rate 0.5
  wait_mark "MMARK done" 60; sleep 2; save "sample-$i"
done
curl -s http://127.0.0.1:31380/_seen > "$R/backend-seen.json"

# 8. release build: does any Dart profiling flag work? (expect: no VM service)
adb shell am force-stop $PKG; sleep 1
launch rel-dartprof-1 normal --ez enable-dart-profiling true --ez trace-systrace true
wait_mark "MMARK done" 60; save rel-dartprof-1
grep -i "vm service\|observatory" "$R/logcat-rel-dartprof-1.txt" > "$R/release-vmservice.txt" || echo "no VM service line in release" > "$R/release-vmservice.txt"

# 9. simpleperf on the RELEASE build (profileable shell; cpu-clock: the emulator has no PMU)
for cg in fp dwarf; do
  adb shell am force-stop $PKG; sleep 1
  adb logcat -c
  adb shell am start -n $ACT --es scenario normal --es run "simpleperf-$cg" --es api $API --es collector $COL > /dev/null
  sleep 0.5
  pid=$(adb shell pidof $PKG | tr -d '\r')
  if [ "$cg" = fp ]; then cgflag="--call-graph fp"; else cgflag="-g"; fi
  adb shell simpleperf record -p "$pid" -e cpu-clock -f 1000 $cgflag --duration 10 -o /data/local/tmp/perf-$cg.data > "$R/simpleperf-record-$cg.txt" 2>&1
  adb pull /data/local/tmp/perf-$cg.data "$R/perf-$cg.data" > /dev/null 2>&1
  save "simpleperf-$cg"
  log "simpleperf $cg: $(tail -2 "$R/simpleperf-record-$cg.txt" | tr '\n' ' ') size=$(stat -c %s "$R/perf-$cg.data" 2>/dev/null)"
done

# 10. Perfetto system trace: release vs profile (are Flutter engine slices there?)
perfetto_run() { # name
  adb shell am force-stop $PKG; sleep 1
  adb shell "perfetto -o /data/misc/perfetto-traces/$1.pftrace -t 12s -b 32mb sched freq gfx view am wm dalvik -a $PKG" > "$R/perfetto-$1.txt" 2>&1 &
  local pp=$!; sleep 2
  adb shell am start -n $ACT --es scenario normal --es run "perfetto-$1" --es api $API --es collector $COL --ez trace-systrace true > /dev/null
  wait $pp; adb pull /data/misc/perfetto-traces/$1.pftrace "$R/perfetto-$1.pftrace" > /dev/null 2>&1
  log "perfetto $1: size=$(stat -c %s "$R/perfetto-$1.pftrace" 2>/dev/null)"
}
perfetto_run release

# ---------------- profile build ----------------
adb install -r "$APK_PROF" > "$R/install-profile.txt" 2>&1; log "installed profile: $(tail -1 "$R/install-profile.txt")"
perfetto_run profile
adb shell am force-stop $PKG; sleep 1
launch prof-1 normal --ez enable-dart-profiling true --ez trace-startup true
wait_mark "MMARK done" 60
vm=$(adb logcat -d | grep -o 'http://127.0.0.1:[0-9]*/[^ ]*' | tail -1)
log "profile VM service: $vm"
if [ -n "$vm" ]; then
  port=$(echo "$vm" | sed -E 's|http://127.0.0.1:([0-9]+)/.*|\1|')
  adb forward tcp:$port tcp:$port
  bun "$ROOT/tools/vm-profile.ts" "$vm" "$R/dartvm-profile" > "$R/dartvm-profile.txt" 2>&1; cat "$R/dartvm-profile.txt" | tee -a "$R/android-steps.txt"
fi
save prof-1
# cold starts of the profile build, for comparison with release
for i in 1 2 3; do adb shell am force-stop $PKG; sleep 1; launch "prof-cold-$i" normal; wait_mark "MMARK done" 60; sleep 1; save "prof-cold-$i"; done
log "android.sh done"
