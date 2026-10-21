package com.keplr.vizor

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView

/** Owns app-switcher privacy separately from the current screen's capture policy. */
internal class AppPrivacyProtection(private val activity: Activity) {
    private var resumed = false
    private var windowFocused = false
    private var sensitiveContentVisible = false
    private var cover: View? = null

    fun onCreate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(false)
        }
        updateSecureFlag()
    }

    fun onResume() {
        resumed = true
        windowFocused = activity.hasWindowFocus()
        updateProtection()
    }

    fun onPause() {
        resumed = false
        windowFocused = false
        updateProtection()
    }

    fun onWindowFocusChanged(hasFocus: Boolean) {
        // Modern recents animations can keep the activity resumed. Focus loss
        // is the earlier boundary; onPause alone leaves its live surface exposed.
        windowFocused = hasFocus
        updateProtection()
    }

    private val interactive: Boolean get() = resumed && windowFocused

    private fun updateProtection() {
        updateSecureFlag()
        if (interactive) {
            cover?.let { (it.parent as? ViewGroup)?.removeView(it) }
            cover = null
        } else {
            showCover()
        }
    }

    private fun showCover() {
        val decor = activity.window.decorView as ViewGroup
        val privacyCover = cover ?: FrameLayout(activity).apply {
            setBackgroundColor(Color.rgb(20, 24, 24))
            isClickable = true
            isFocusable = true
            contentDescription = "Sensitive content hidden"
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            val iconSize = (50 * resources.displayMetrics.density).toInt()
            addView(ImageView(context).apply {
                setImageResource(android.R.drawable.ic_lock_lock)
                setColorFilter(Color.WHITE)
            }, FrameLayout.LayoutParams(iconSize, iconSize, Gravity.CENTER))
        }.also {
            decor.addView(it, ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            ))
            cover = it
        }
        decor.bringChildToFront(privacyCover)
    }

    fun setSensitiveContentVisible(visible: Boolean) {
        sensitiveContentVisible = visible
        updateSecureFlag()
    }

    private fun updateSecureFlag() {
        // The recents-only API does not exclude every live/started task surface.
        // Every non-interactive window needs FLAG_SECURE, including API 33+.
        if (sensitiveContentVisible || !interactive) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
}
