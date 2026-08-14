package com.trimtime.app

import android.app.Activity
import android.content.Intent
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val phoneHintChannel = "com.trimtime.app/phone_hint"
    private val phoneHintRequestCode = 41091
    private var pendingPhoneHintResult: MethodChannel.Result? = null

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
