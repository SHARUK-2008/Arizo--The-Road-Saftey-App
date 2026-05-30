package com.example.near_miss_detector

import android.app.Activity
import android.content.Context
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.os.Build

object SmsHelper {
    var activity: Activity? = null

    fun sendSms(phoneNumber: String, message: String): Boolean {
        val context = activity?.applicationContext ?: return false

        return try {
            val smsManager = getSmsManager(context)
                ?: throw Exception("Could not get SmsManager")

            val parts = smsManager.divideMessage(message)
            if (parts.size > 1) {
                smsManager.sendMultipartTextMessage(
                    phoneNumber, null, parts, null, null
                )
            } else {
                smsManager.sendTextMessage(
                    phoneNumber, null, message, null, null
                )
            }
            true
        } catch (e: Exception) {
            e.printStackTrace()
            throw e
        }
    }

    private fun getSmsManager(context: Context): SmsManager? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val subscriptionManager =
                    context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                            as? SubscriptionManager

                val activeSubId = subscriptionManager
                    ?.activeSubscriptionInfoList
                    ?.firstOrNull()
                    ?.subscriptionId

                if (activeSubId != null) {
                    context.getSystemService(SmsManager::class.java)
                        ?.createForSubscriptionId(activeSubId)
                } else {
                    context.getSystemService(SmsManager::class.java)
                }
            } else {
                val subscriptionManager = context
                    .getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                        as? SubscriptionManager

                @Suppress("DEPRECATION")
                val activeSubId = subscriptionManager
                    ?.activeSubscriptionInfoList
                    ?.firstOrNull()
                    ?.subscriptionId
                    ?: SubscriptionManager.getDefaultSmsSubscriptionId()

                if (activeSubId != SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
                    @Suppress("DEPRECATION")
                    SmsManager.getSmsManagerForSubscriptionId(activeSubId)
                } else {
                    @Suppress("DEPRECATION")
                    SmsManager.getDefault()
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
    }
}
