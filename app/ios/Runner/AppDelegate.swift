import Flutter
import UIKit

// Spike channel: launch args (SPIKE_* env), process start time, native crash/hang triggers,
// and a tiny main-thread watchdog that records stalls (duration only; no main stack from Swift).
final class SpikeWatchdog {
  static var hangs: [[String: Any]] = []
  static let lock = NSLock()
  static var started = false
  static func start() {
    if started { return }
    started = true
    let t = Thread {
      while true {
        var answered = false
        let t0 = Date()
        DispatchQueue.main.async { answered = true }
        Thread.sleep(forTimeInterval: 2.0)
        if !answered {
          while !answered { Thread.sleep(forTimeInterval: 0.05) }
          lock.lock(); hangs.append(["duration_ms": Int(Date().timeIntervalSince(t0) * 1000), "stack": ""]); lock.unlock()
        }
      }
    }
    t.name = "spike-watchdog"
    t.start()
  }
}

func processStartEpochMs() -> Double? {
  var kinfo = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
  guard sysctl(&mib, u_int(mib.count), &kinfo, &size, nil, 0) == 0 else { return nil }
  let tv = kinfo.kp_proc.p_starttime
  return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    SpikeWatchdog.start()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SpikeNative") else { return }
    let ch = FlutterMethodChannel(name: "spike/native", binaryMessenger: registrar.messenger())
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "args":
        var m: [String: String] = [:]
        for (k, v) in ProcessInfo.processInfo.environment where k.hasPrefix("SPIKE_") {
          m[String(k.dropFirst(6)).lowercased()] = v
        }
        result(m)
      case "processStart":
        result(["process_start_epoch_ms": processStartEpochMs() ?? 0])
      case "takeHangs":
        SpikeWatchdog.lock.lock(); let l = SpikeWatchdog.hangs; SpikeWatchdog.hangs = []; SpikeWatchdog.lock.unlock()
        result(l)
      case "crashNative":
        result(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          let items: [Int] = []
          _ = items[Int(getpid() % 7) + 3] // Swift index out of range -> EXC_BREAKPOINT
        }
      case "hangNative":
        let ms = ((call.arguments as? [String: Any])?["ms"] as? Int) ?? 7000
        result(nil)
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
