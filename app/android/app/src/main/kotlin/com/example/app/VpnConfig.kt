package com.example.app

import android.util.Log
import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object VpnConfig {
    val SERVER_IP: String = BuildConfig.SERVER_IP
    val SERVER_PORT: Int = BuildConfig.SERVER_PORT
    const val TUNNEL_IP = "10.1.0.3" // rendezvous
    const val TUNNEL_PREFIX = 24
    const val DNS_SERVER = "8.8.8.8" // googler
    const val SESSION_NAME = "XorVPN"
    const val MTU = 1200
    const val MAX_UDP_PACKET_SIZE = 1530 // 1500-byte payload + 30-byte protocol overhead

    private const val TAG = "VpnConfig"
    private const val HKDF_SALT = "vpn-server-2026"
    private const val NONCE_SIZE = 12
    private const val GCM_TAG_SIZE = 16
    private const val HEADER_SIZE = 2
    private const val PACKET_OVERHEAD = HEADER_SIZE + NONCE_SIZE + GCM_TAG_SIZE
    private const val GCM_TAG_BITS = GCM_TAG_SIZE * 8
    private val rotationSecs: Long = BuildConfig.ROTATION_INTERVAL_SEC
    private val secureRandom = SecureRandom()

    fun currentWindowIndex(): Long =
        System.currentTimeMillis() / 1000L / rotationSecs

    fun deriveCryptoKeyForWindow(windowIndex: Long): ByteArray {
        val secret = BuildConfig.MASTER_SECRET.toByteArray(Charsets.UTF_8)
        val salt = HKDF_SALT.toByteArray(Charsets.UTF_8)
        val windowBytes = ByteBuffer.allocate(Long.SIZE_BYTES).putLong(windowIndex).array()
        val info = "crypto-key:".toByteArray(Charsets.UTF_8) + windowBytes
        return hkdfDeriveKey(secret, salt, info, 32)
    }

    fun encryptPacket(type: Byte, payload: ByteArray): ByteArray {
        val windowIndex = currentWindowIndex()
        val header = byteArrayOf(type, (windowIndex and 0xFF).toByte())
        val nonce = ByteArray(NONCE_SIZE).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(deriveCryptoKeyForWindow(windowIndex), "AES"),
            GCMParameterSpec(GCM_TAG_BITS, nonce),
        )
        cipher.updateAAD(header)
        val ciphertextAndTag = cipher.doFinal(payload)
        return header + nonce + ciphertextAndTag
    }

    fun decryptPacket(data: ByteArray): Pair<Byte, ByteArray>? {
        if (data.size < PACKET_OVERHEAD) {
            Log.w(TAG, "Dropping undersized encrypted packet (${data.size} bytes)")
            return null
        }

        val header = data.copyOfRange(0, HEADER_SIZE)
        val keyVersion = header[1]
        val currentWindow = currentWindowIndex()
        val previousWindow = currentWindow - 1
        val matchedWindow = when (keyVersion) {
            (currentWindow and 0xFF).toByte() -> currentWindow
            (previousWindow and 0xFF).toByte() -> previousWindow
            else -> {
                Log.w(
                    TAG,
                    "Dropping packet with key version 0x${keyVersion.toUByte().toString(16)}; " +
                        "only current/previous windows are accepted. Check device clock synchronization.",
                )
                return null
            }
        }

        val nonce = data.copyOfRange(HEADER_SIZE, HEADER_SIZE + NONCE_SIZE)
        val ciphertextAndTag = data.copyOfRange(HEADER_SIZE + NONCE_SIZE, data.size)
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(deriveCryptoKeyForWindow(matchedWindow), "AES"),
                GCMParameterSpec(GCM_TAG_BITS, nonce),
            )
            cipher.updateAAD(header)
            Pair(header[0], cipher.doFinal(ciphertextAndTag))
        } catch (_: GeneralSecurityException) {
            Log.w(TAG, "Dropping packet that failed AES-GCM authentication")
            null
        }
    }

    // HKDF-SHA256 extract and expand (RFC 5869).
    private fun hkdfDeriveKey(
        secret: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        length: Int,
    ): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = mac.doFinal(secret)

        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val output = ByteArray(length)
        var previousBlock = ByteArray(0)
        var position = 0
        var counter = 1
        while (position < length) {
            mac.update(previousBlock)
            mac.update(info)
            mac.update(counter.toByte())
            previousBlock = mac.doFinal()
            val copyLength = minOf(previousBlock.size, length - position)
            previousBlock.copyInto(output, position, 0, copyLength)
            position += copyLength
            counter++
        }
        return output
    }
}
