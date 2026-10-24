package dev.naominet.lazer

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/// The app's own haptics channel, mirroring the iOS `AppDelegate` handler.
///
/// Flutter's built-in `HapticFeedback` maps taps to `CLOCK_TICK`, which many
/// Android devices do not implement and which ignores the user's intensity
/// setting. Driving the vibrator directly gives every device the same short
/// tick and lets the analytics-free intensity slider control its strength.
class MainActivity : AudioServiceActivity() {
    private var vibrator: Vibrator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HAPTICS_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "impact") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val intensity = ((call.argument<Number>("intensity") ?: .5).toFloat())
                    .coerceIn(0f, 1f)
                val kind = call.argument<String>("kind") ?: "tap"
                impact(intensity, kind)
                result.success(null)
            }
    }

    private fun impact(intensity: Float, kind: String) {
        val vibrator = vibrator ?: resolveVibrator().also { vibrator = it } ?: return
        if (!vibrator.hasVibrator()) return
        val milliseconds = when (kind) {
            "boundary" -> 26L
            "detent" -> 8L
            else -> 12L
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Amplitude 1..255: 0 is not a valid one-shot amplitude, and a
            // non-zero floor keeps the faintest setting perceptible.
            val amplitude = (intensity * 255f).roundToInt().coerceIn(1, 255)
            vibrator.vibrate(VibrationEffect.createOneShot(milliseconds, amplitude))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(milliseconds)
        }
    }

    private fun resolveVibrator(): Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    private companion object {
        const val HAPTICS_CHANNEL = "dev.naominet.lazer/haptics"
    }
}
