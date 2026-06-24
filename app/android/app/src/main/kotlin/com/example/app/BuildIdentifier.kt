package com.example.app

import android.os.Build

object BuildIdentifier {
    private const val MAX_BYTES = 64
    private val allowedChars = Regex("[A-Za-z0-9 ._:/+\\-]")
    private val numericVersion = Regex("""\d+(?:\.\d+)*""")

    fun current(): String {
        val raw = "${Build.BRAND}/${Build.MODEL}:${Build.VERSION.RELEASE}/" +
            "${Build.VERSION.SDK_INT}+${BuildConfig.VERSION_CODE}"
        return sanitize(raw)
    }

    fun sanitize(value: String?): String {
        val sanitized = value.orEmpty()
            .map { if (allowedChars.matches(it.toString())) it else '_' }
            .joinToString("")
            .takeUtf8Bytes(MAX_BYTES)
        return sanitized.ifEmpty { "unknown" }
    }

    fun appVersion(): String =
        numericVersion.find(BuildConfig.VERSION_NAME)?.value ?: "0.0.0"

    private fun String.takeUtf8Bytes(maxBytes: Int): String {
        val builder = StringBuilder()
        var byteCount = 0
        for (char in this) {
            val charBytes = char.toString().toByteArray(Charsets.UTF_8).size
            if (byteCount + charBytes > maxBytes) break
            builder.append(char)
            byteCount += charBytes
        }
        return builder.toString()
    }
}
