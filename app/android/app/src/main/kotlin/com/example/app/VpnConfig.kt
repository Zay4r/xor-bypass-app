package com.example.app

import java.nio.ByteBuffer
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object VpnConfig {
    val SERVER_IP: String = BuildConfig.SERVER_IP
    val SERVER_PORT: Int = BuildConfig.SERVER_PORT
    const val TUNNEL_IP = "10.1.0.3" // rendezvous
    const val TUNNEL_PREFIX = 24
    const val DNS_SERVER = "8.8.8.8" // googler
    const val SESSION_NAME = "XorVPN"
    const val MTU = 1200

    private const val HKDF_SALT = "vpn-server-2026"
    private val ROTATION_INTERVAL_SEC: Long = BuildConfig.ROTATION_INTERVAL_SEC

    fun currentWindowIndex(): Long =
        System.currentTimeMillis() / 1000L / ROTATION_INTERVAL_SEC

    fun currentKeyVersion(): Byte =
        (currentWindowIndex() and 0xFF).toByte()

    fun deriveKeysForWindow(windowIdx: Long): Pair<ByteArray, ByteArray> {
        val secret = BuildConfig.MASTER_SECRET.toByteArray(Charsets.UTF_8)
        val salt = HKDF_SALT.toByteArray(Charsets.UTF_8)
        val info = ByteBuffer.allocate(8).putLong(windowIdx).array()

        val cryptoKey = hkdfDeriveKey(
            secret, salt,
            "crypto-key:".toByteArray() + info,
            32
        )
        val obfuscateKey = hkdfDeriveKey(
            secret, salt,
            "obfuscate-key:".toByteArray() + info,
            32
        )
        return Pair(cryptoKey, obfuscateKey)
    }

    fun currentKeys(): Pair<ByteArray, ByteArray> =
        deriveKeysForWindow(currentWindowIndex())

    fun xorObfuscatePayload(data: ByteArray, key: ByteArray) {
    if (key.isEmpty() || data.size <= 2) return
    for (i in 2 until data.size) {
        data[i] = (data[i].toInt() xor key[(i - 2) % key.size].toInt()).toByte()
    }
}

    // HKDF-SHA256: extract then expand (RFC 5869)
    private fun hkdfDeriveKey(
        secret: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        length: Int
    ): ByteArray {
        // Extract
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = mac.doFinal(secret)

        // Expand
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val output = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            mac.update(t)
            mac.update(info)
            mac.update(counter.toByte())
            t = mac.doFinal()
            val copy = minOf(t.size, length - pos)
            t.copyInto(output, pos, 0, copy)
            pos += copy
            counter++
        }
        return output
    }
}