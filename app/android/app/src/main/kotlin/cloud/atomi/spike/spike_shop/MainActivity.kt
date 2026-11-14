package cloud.atomi.spike.spike_shop

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean

// Spike channel: launch args, process start time, native crash/hang triggers, and a tiny
// main-thread watchdog (what Sentry/Faro do natively) that records stalls with the main stack.
class MainActivity : FlutterActivity() {
    companion object {
        val hangs: MutableList<Map<String, Any>> = Collections.synchronizedList(mutableListOf())
        @Volatile var watchdogStarted = false

        fun startWatchdog() {
            if (watchdogStarted) return
            watchdogStarted = true
            val main = Handler(Looper.getMainLooper())
            val mainThread = Looper.getMainLooper().thread
            Thread({
                while (true) {
                    val answered = AtomicBoolean(false)
                    val t0 = SystemClock.uptimeMillis()
                    main.post { answered.set(true) }
                    Thread.sleep(2000)
                    if (!answered.get()) {
                        val stack = mainThread.stackTrace.take(25).joinToString("\n") { it.toString() }
                        while (!answered.get()) Thread.sleep(50)
                        hangs.add(mapOf("duration_ms" to (SystemClock.uptimeMillis() - t0), "stack" to stack))
                    }
                }
            }, "spike-watchdog").apply { isDaemon = true }.start()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        startWatchdog()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spike/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "args" -> {
                    val m = HashMap<String, String>()
                    intent?.extras?.keySet()?.forEach { k -> intent.extras?.get(k)?.let { m[k] = it.toString() } }
                    result.success(m)
                }
                "processStart" -> {
                    val now = System.currentTimeMillis()
                    val el = SystemClock.elapsedRealtime()
                    val m = HashMap<String, Long>()
                    m["process_start_epoch_ms"] = now - (el - Process.getStartElapsedRealtime())
                    if (Build.VERSION.SDK_INT >= 33) m["launch_requested_epoch_ms"] = now - (el - Process.getStartRequestedElapsedRealtime())
                    result.success(m)
                }
                "takeHangs" -> { val l = ArrayList(hangs); hangs.clear(); result.success(l) }
                "crashNative" -> {
                    result.success(null)
                    Handler(Looper.getMainLooper()).postDelayed({ throw IllegalStateException("spike native crash: Kotlin main thread") }, 100)
                }
                "hangNative" -> {
                    val ms = (call.argument<Int>("ms") ?: 7000).toLong()
                    result.success(null)
                    Handler(Looper.getMainLooper()).post { Thread.sleep(ms) }
                }
                else -> result.notImplemented()
            }
        }
    }
}
