package com.keplr.vizor

import android.app.Activity
import android.os.Build
import android.view.ViewGroup
import android.view.WindowManager
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.*
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30, 32, 33, 34], manifest = Config.NONE)
class AppPrivacyProtectionTest {
    private lateinit var activity: Activity
    private lateinit var protection: AppPrivacyProtection

    @Before fun setUp() {
        activity = spy(Robolectric.buildActivity(Activity::class.java).setup().get())
        if (Build.VERSION.SDK_INT >= 33) {
            doNothing().`when`(activity).setRecentsScreenshotEnabled(false)
        }
        protection = AppPrivacyProtection(activity)
        protection.onCreate()
        resumeFocused()
    }

    private fun resumeFocused() {
        protection.onResume()
        protection.onWindowFocusChanged(true)
    }

    private fun isSecure() = activity.window.attributes.flags and
        WindowManager.LayoutParams.FLAG_SECURE != 0

    private fun coverCount(): Int {
        val decor = activity.window.decorView as ViewGroup
        return (0 until decor.childCount).count {
            decor.getChildAt(it).contentDescription == "Sensitive content hidden"
        }
    }

    @Test fun ordinaryForegroundAllowsCapture() {
        assertFalse(isSecure())
        assertEquals(0, coverCount())
        if (Build.VERSION.SDK_INT >= 33) {
            verify(activity).setRecentsScreenshotEnabled(false)
        }
    }

    @Test fun everyBackgroundScreenIsCoveredAndLiveRecentsAreSecure() {
        protection.onPause()
        assertEquals(1, coverCount())
        assertTrue(isSecure())
        protection.onPause()
        assertEquals(1, coverCount())
        resumeFocused()
        assertEquals(0, coverCount())
        assertFalse(isSecure())
    }

    @Test fun sensitiveCaptureExclusionSurvivesResume() {
        protection.setSensitiveContentVisible(true)
        assertTrue(isSecure())
        protection.onPause()
        resumeFocused()
        assertTrue(isSecure())
        assertEquals(0, coverCount())
        protection.setSensitiveContentVisible(false)
        assertFalse(isSecure())
    }

    @Test fun removingSensitiveScreenInBackgroundCannotReleaseRecentsProtection() {
        protection.setSensitiveContentVisible(true)
        protection.onPause()
        protection.setSensitiveContentVisible(false)
        assertTrue(isSecure())
        assertEquals(1, coverCount())
        resumeFocused()
        assertFalse(isSecure())
    }

    @Test fun sensitiveScreenCanBecomeVisibleWhileBackgrounded() {
        protection.onPause()
        protection.setSensitiveContentVisible(true)
        resumeFocused()
        assertTrue(isSecure())
        assertEquals(0, coverCount())
    }

    @Test fun liveRecentsFocusLossIsProtectedWithoutWaitingForPause() {
        protection.onWindowFocusChanged(false)
        assertTrue(isSecure())
        assertEquals(1, coverCount())
        protection.setSensitiveContentVisible(false)
        assertTrue(isSecure())
        protection.onWindowFocusChanged(true)
        assertFalse(isSecure())
        assertEquals(0, coverCount())
    }

    @Test fun resumeBeforeFocusCannotUncoverTheWindow() {
        protection.onPause()
        protection.onResume()
        assertTrue(isSecure())
        assertEquals(1, coverCount())
        protection.setSensitiveContentVisible(true)
        protection.onWindowFocusChanged(true)
        assertTrue(isSecure())
        assertEquals(0, coverCount())
    }
}
