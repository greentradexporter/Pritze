package com.trimtime.app

import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val phoneHintChannel = "com.trimtime.app/phone_hint"
    private val ownerAlertChannel = "com.trimtime.app/owner_alerts"
    private val phoneHintRequestCode = 41091
    private var pendingPhoneHintResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        handleOwnerBookingDecision(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        handleOwnerBookingDecision(intent)
        super.onNewIntent(intent)
    }

    private fun handleOwnerBookingDecision(intent: Intent?) {
        if (intent?.action != "SELECT_FOREGROUND_NOTIFICATION" ||
            intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        val status = when (intent.getStringExtra("actionId")) {
            "accept_instant_booking" -> "confirmed"
            "reject_instant_booking" -> "rejected"
            else -> return
        }
        val payload = try {
            JSONObject(intent.getStringExtra("payload") ?: return)
        } catch (_: Exception) {
            return
        }
        val bookingId = payload.optString("bookingId").trim()
        if (bookingId.isEmpty() || payload.optString("isInstant") != "true") return

        // Stop the tagged notification before Flutter/Firebase startup. The
        // notification plugin's foreground-action path cancels only by ID.
        val notifications = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val id = intent.getIntExtra("notificationId", 790001)
        val tag = intent.getStringExtra("notificationTag")

        // Dart's uncached preferences use this same native file. A concurrent
        // FCM isolate can see the decision before the activity starts Dart.
        val now = System.currentTimeMillis()
        getSharedPreferences("pritze_owner_booking_actions", MODE_PRIVATE)
            .edit()
            .putLong("pritze.notifications.ownerAlertStopped.$bookingId", now + 600_000L)
            .putString("pritze.notifications.pendingOwnerBookingAction.$bookingId", "$status|$now")
            .commit()
        if (tag == null) notifications.cancel(id) else notifications.cancel(tag, id)
        notifications.cancel("pritze_owner_booking_request", 790001)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != phoneHintRequestCode) {
            return
        }
        val methodResult = pendingPhoneHintResult ?: return
        pendingPhoneHintResult = null
        if (resultCode != Activity.RESULT_OK) {
            methodResult.error("cancelled", "Phone number selection was cancelled.", null)
            return
        }
        try {
            val phoneNumber = Identity.getSignInClient(this)
                .getPhoneNumberFromIntent(data)
            methodResult.success(phoneNumber)
        } catch (error: Exception) {
            methodResult.error("unavailable", error.message, null)
        }
    }

    // Whether this phone will actually let the booking alert behave like a
    // ringing call, and the settings screens that fix it when it will not.
    // Both conditions are silent failures otherwise: the alert is posted, the
    // owner simply never sees or hears it.
    private fun configureOwnerAlertChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ownerAlertChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canUseFullScreenIntent" -> {
                        // Granted on install before Android 14.
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            result.success(true)
                        } else {
                            val manager =
                                getSystemService(NOTIFICATION_SERVICE) as NotificationManager
                            result.success(manager.canUseFullScreenIntent())
                        }
                    }
                    "openFullScreenIntentSettings" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            result.success(false)
                        } else {
                            result.success(
                                startSettings(
                                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                ),
                            )
                        }
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(power.isIgnoringBatteryOptimizations(packageName))
                    }
                    "openBatteryOptimizationSettings" -> {
                        // The list screen, not a direct exemption request: the
                        // direct request needs a permission Play restricts.
                        result.success(
                            startSettings(
                                Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS,
                                withPackage = false,
                            ),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startSettings(action: String, withPackage: Boolean = true): Boolean {
        return try {
            val intent = Intent(action)
            if (withPackage) intent.data = Uri.fromParts("package", packageName, null)
            startActivity(intent)
            true
        } catch (_: Exception) {
            // Some builds ship without these screens. The caller falls back to
            // telling the owner where to look.
            false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        configureOwnerAlertChannel(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, phoneHintChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "requestPhoneNumber") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingPhoneHintResult != null) {
                    result.error("in_progress", "Phone number selection is already open.", null)
                    return@setMethodCallHandler
                }
                pendingPhoneHintResult = result
                val request = GetPhoneNumberHintIntentRequest.builder().build()
                Identity.getSignInClient(this)
                    .getPhoneNumberHintIntent(request)
                    .addOnSuccessListener { pendingIntent ->
                        try {
                            startIntentSenderForResult(
                                pendingIntent.intentSender,
                                phoneHintRequestCode,
                                null,
                                0,
                                0,
                                0,
                            )
                        } catch (error: Exception) {
                            pendingPhoneHintResult = null
                            result.error("unavailable", error.message, null)
                        }
                    }
                    .addOnFailureListener { error ->
                        pendingPhoneHintResult = null
                        result.error("unavailable", error.message, null)
                    }
            }
    }
}
