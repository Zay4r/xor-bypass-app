package com.example.app

import java.security.MessageDigest

object VpnConfig {
    val SERVER_IP: String = BuildConfig.SERVER_IP
    val SERVER_PORT: Int = BuildConfig.SERVER_PORT
    const val TUNNEL_IP = "10.1.0.3" // rendezvous
    const val TUNNEL_PREFIX = 24
    const val DNS_SERVER = "8.8.8.8" // googler
    const val SESSION_NAME = "XorVPN"
    const val MTU = 1200

    private fun deriveKeys(): Pair<ByteArray, ByteArray> {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(BuildConfig.MASTER_SECRET.toByteArray())
        return Pair(hash.copyOfRange(0, 16), hash.copyOfRange(16, 32))
    }

    val CRYPTO_KEY: ByteArray = deriveKeys().first
    val OBFUSCATE_KEY: ByteArray = deriveKeys().second

    fun xorObfuscate(data: ByteArray, key: ByteArray) {
        if (key.isEmpty()) return
        for (i in data.indices) {
            data[i] = (data[i].toInt() xor key[i % key.size].toInt()).toByte()
        }
    }
}