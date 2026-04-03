package com.github.kr328.clash.common.compat

import android.app.Application
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import com.github.kr328.clash.common.log.Log
import java.io.BufferedReader
import java.io.FileReader

val Application.currentProcessName: String
    get() {
        if (Build.VERSION.SDK_INT >= 28)
            return Application.getProcessName()

        return try {
            BufferedReader(FileReader("/proc/self/cmdline")).use {
                it.readLine().trim { c -> c.toInt() == 0 }
            }
        } catch (throwable: Throwable) {
            Log.w("Resolve process name: $throwable")
            packageName
        }
    }

fun Drawable.foreground(): Drawable {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        this is AdaptiveIconDrawable && this.background == null
    ) {
        return this.foreground
    }
    return this
}
