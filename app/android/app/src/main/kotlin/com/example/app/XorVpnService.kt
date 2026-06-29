package com.example.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

private const val TAG           = "XorVpnService"
private const val NOTIF_CHANNEL = "xor_vpn"
private const val NOTIF_ID      = 1

// Packet type constants — must match server Crypto.go exactly
private const val PKT_AUTH_HELLO = 0x01.toByte()
private const val PKT_DATA      = 0x02.toByte()
private const val PKT_AUTH_CHALLENGE = 0x03.toByte()
private const val PKT_AUTH_PROOF = 0x04.toByte()
private const val PKT_AUTH_OK   = 0xA0.toByte()
private const val PKT_AUTH_DENY = 0xA1.toByte()

private data class AuthResult(
    val tunnelIp: String,
    val tunnelIpBytes: ByteArray,
    val prefixLength: Int,
    val mtu: Int,
    val updateNotice: UpdateNotice?,
    val sessionKeyVersion: Byte,
    val clientToServerDataKey: ByteArray,
    val serverToClientDataKey: ByteArray,
)

private data class UpdateNotice(
    val latestVersion: String?,
    val updateUrl: String?,
) {
    fun toJson(): String = JSONObject().apply {
        latestVersion?.let { put("latest_version", it) }
        updateUrl?.let { put("update_url", it) }
    }.toString()
}

private data class DataSessionKeys(
    val keyVersion: Byte,
    val clientToServer: ByteArray,
    val serverToClient: ByteArray,
)

private data class AuthDenial(
    val reason: String,
    val minVersion: String?,
    val latestVersion: String?,
    val updateUrl: String?,
    val updateAvailable: Boolean,
) {
    val requiresUpdate: Boolean
        get() = reason == "app_version_unsupported" || reason == "app_version_required"

    fun toJson(): String = JSONObject().apply {
        put("reason", reason)
        minVersion?.let { put("min_version", it) }
        latestVersion?.let { put("latest_version", it) }
        updateUrl?.let { put("update_url", it) }
        put("update_available", updateAvailable)
    }.toString()
}

private class AuthDeniedException(val denial: AuthDenial) : Exception(denial.reason)

class XorVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var running = false
    private var buildNumber = ""
    private var appVersion = ""
    private var platform = ""
    private var deviceId = ""
    private var publicKey = ""
    private var targetPackages = DEFAULT_TARGET_PACKAGES
    private val startLock = Any()
    private var handshakeInProgress = false
    private var assignedAuthResult: AuthResult? = null

    companion object {
        var flutterChannel: MethodChannel? = null

        private const val AUTH_MAX_ATTEMPTS = 3
        private const val AUTH_PACKET_TIMEOUT_MS = 5_000L
        private const val SIGNING_TIMEOUT_MS = 5_000L
        private const val AUTH_RETRY_DELAY_MS = 1_000L

        private val DEFAULT_TARGET_PACKAGES = setOf(
            "com.facebook.katana",
            "com.facebook.lite",
            "com.facebook.orca",
            "com.android.chrome",
            "com.instagram.android",
            "com.viber.voip",
        )
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            stopVpn()
            return START_NOT_STICKY
        }
        synchronized(startLock) {
            if (running || handshakeInProgress) return START_NOT_STICKY
            handshakeInProgress = true
        }
        buildNumber = BuildIdentifier.sanitize(
            intent?.getStringExtra("buildNumber") ?: BuildIdentifier.current(),
        )
        appVersion = BuildIdentifier.appVersion()
        platform = "android"
        deviceId = intent?.getStringExtra("deviceId").orEmpty()
        publicKey = intent?.getStringExtra("publicKey").orEmpty()
        targetPackages = VpnActions.sanitizeTargetPackages(
            intent?.getStringArrayListExtra("targetPackages").orEmpty(),
        ).ifEmpty { DEFAULT_TARGET_PACKAGES }
        startForegroundNotification()
        Thread { startVpn() }.start()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    // -----------------------------------------------------------------------
    // Main tunnel
    // -----------------------------------------------------------------------

    private fun startVpn() {
        try {
            notify("connecting")

            val serverAddr = InetAddress.getByName(VpnConfig.SERVER_IP)
            udpSocket = DatagramSocket()
            val socket = udpSocket!!
            protect(socket)

            // ── Step 1: Auth handshake ─────────────────────────────────────
            val authResult = try {
                performAuth(socket, serverAddr)
            } catch (e: AuthDeniedException) {
                if (e.denial.reason == "not_provisioned") {
                    VpnActions.markNotProvisioned(this)
                    VpnActions.stopMonitor(this)
                    Log.w(TAG, "Device has not been provisioned on the server; device_id=$deviceId")
                }
                if (e.denial.requiresUpdate) {
                    notify("update_required:${e.denial.toJson()}")
                } else {
                    notify("denied:${e.denial.reason}")
                }
                stopVpn()
                return
            }
            assignedAuthResult = authResult
            udpSocket!!.soTimeout = 0
            // ── Step 2: Build TUN interface ────────────────────────────────
            val builder = Builder()
            builder.addAddress(authResult.tunnelIp, authResult.prefixLength)
            builder.addDnsServer(VpnConfig.DNS_SERVER)
            builder.addRoute("0.0.0.0", 0)
            builder.allowFamily(android.system.OsConstants.AF_INET)
            builder.setSession(VpnConfig.SESSION_NAME)
            builder.setMtu(authResult.mtu)

            val allowedAppCount = addAllowedTargetApps(builder)
            if (allowedAppCount == 0) {
                notify("error: Target app is not installed")
                stopVpn()
                return
            }

            vpnInterface = builder.establish() ?: run {
                notify("error: VPN permission not granted")
                stopVpn()
                return
            }

            running = true
            notify("connected")
            authResult.updateNotice?.let {
                notify("update_available:${it.toJson()}")
            }

            // ── Step 3: phone → encrypt → server ──────────────────────────
            Thread {
                val sock = udpSocket ?: return@Thread
                val buffer = ByteArray(authResult.mtu)
                val input = FileInputStream(vpnInterface!!.fileDescriptor)
                while (running) {
                    try {
                        val n = input.read(buffer)
                        if (n <= 0) continue

                        val packet = buffer.copyOf(n)
                        if (!hasAssignedIpv4Source(packet, authResult.tunnelIpBytes)) {
                            Log.w(TAG, "Dropping outbound packet with non-assigned source IP")
                            continue
                        }
                        val wrapped = VpnConfig.encryptPacketWithKey(
                            PKT_DATA,
                            authResult.sessionKeyVersion,
                            authResult.clientToServerDataKey,
                            packet,
                        )

                        sock.send(
                            DatagramPacket(wrapped, wrapped.size, serverAddr, VpnConfig.SERVER_PORT),
                        )
                    } catch (e: Exception) {
                        if (running) Log.w(TAG, "Send error: ${e.message}")
                    }
                }
            }.start()

            // ── Step 4: server → decrypt → phone ──────────────────────────
            // Also handles mid-session PKT_AUTH_DENY kick from the server.
            Thread {
                val sock      = udpSocket ?: return@Thread   // snapshot — safe from concurrent null
                val buffer    = ByteArray(VpnConfig.MAX_UDP_PACKET_SIZE)
                val output    = FileOutputStream(vpnInterface!!.fileDescriptor)
                val udpPacket = DatagramPacket(buffer, buffer.size)
                while (running) {
                    try {
                        udpPacket.length = buffer.size
                        sock.receive(udpPacket)
                        val raw = buffer.copyOf(udpPacket.length)
                        val decrypted = when (raw.firstOrNull()) {
                            PKT_DATA -> VpnConfig.decryptPacketWithKey(
                                raw,
                                authResult.sessionKeyVersion,
                                authResult.serverToClientDataKey,
                            )
                            else -> VpnConfig.decryptPacket(raw)
                        } ?: continue
                        val (type, payload) = decrypted

                        when (type) {
                            PKT_DATA -> {
                                // Normal tunnel traffic — write to TUN
                                output.write(payload)
                            }

                            PKT_AUTH_DENY -> {
                                // Server kicked us mid-session (blocked or expired).
                                val denial = parseAuthDenial(payload)
                                val reason = denial.reason
                                Log.w(TAG, "Mid-session kick received — reason: $reason")
                                // notify Flutter first, then tear down everything via stopVpn()
                                if (denial.requiresUpdate) {
                                    notify("update_required:${denial.toJson()}")
                                } else {
                                    notify("denied:${denial.reason}")
                                }
                                stopVpn()
                            }

                            else -> Log.w(TAG, "Unexpected packet type 0x${type.toString(16)} — ignored")
                        }

                    } catch (e: Exception) {
                        if (running) Log.w(TAG, "Recv error: ${e.message}")
                    }
                }
            }.start()

        } catch (e: Exception) {
            Log.e(TAG, "Fatal tunnel error: ${e.message}", e)
            notify("error: ${e.message}")
            stopSelf()
        } finally {
            synchronized(startLock) {
                handshakeInProgress = false
            }
            buildNumber = ""
            appVersion = ""
            platform = ""
            deviceId = ""
            publicKey = ""
        }
    }

    // -----------------------------------------------------------------------
    // Auth handshake
    // -----------------------------------------------------------------------

    private fun performAuth(socket: DatagramSocket, serverAddr: InetAddress): AuthResult {
        requireValidPublicIdentity()
        val publicKeyBytes = Base64.decode(publicKey, Base64.DEFAULT)
        val hello = JSONObject()
            .put("build_number", buildNumber)
            .put("platform", platform)
            .put("app_version", appVersion)
            .put("device_id", deviceId)
            .put("public_key", publicKey)
            .toString()
            .toByteArray(Charsets.UTF_8)

        repeat(AUTH_MAX_ATTEMPTS) { attempt ->
            var challengeId: ByteArray? = null
            var challenge: ByteArray? = null
            try {
                Log.d(TAG, "Authentication attempt ${attempt + 1}/$AUTH_MAX_ATTEMPTS")
                sendEncrypted(socket, serverAddr, PKT_AUTH_HELLO, hello)
                val challengePacket = receiveAuthenticatedPacket(socket)
                if (challengePacket.type == PKT_AUTH_DENY) {
                    throw AuthDeniedException(parseAuthDenial(challengePacket.payload))
                }
                if (challengePacket.type != PKT_AUTH_CHALLENGE) {
                    throw IllegalStateException("Expected AUTH_CHALLENGE")
                }

                val challengeJson = JSONObject(challengePacket.payload.toString(Charsets.UTF_8))
                challengeId = Base64.decode(challengeJson.getString("challenge_id"), Base64.DEFAULT)
                challenge = Base64.decode(challengeJson.getString("challenge"), Base64.DEFAULT)
                if (challengeId.size != 16 || challenge.size != 32) {
                    throw IllegalArgumentException("Malformed authentication challenge")
                }

                val signatureBytes = Base64.decode(
                    requestSignature(challengeId, challenge),
                    Base64.DEFAULT,
                )
                if (signatureBytes.size != 64) {
                    throw IllegalStateException("Invalid authentication signature")
                }
                val proofWindow = VpnConfig.currentWindowIndex()
                val proofKeyVersion = (proofWindow and 0xFF).toByte()
                val proofAuthKey = VpnConfig.deriveCryptoKeyForWindow(proofWindow)
                val sessionKeys = deriveDataSessionKeys(
                    keyVersion = proofKeyVersion,
                    authKey = proofAuthKey,
                    challengeId = challengeId,
                    challenge = challenge,
                    publicKeyBytes = publicKeyBytes,
                    appVersion = appVersion,
                    platform = platform,
                    signatureBytes = signatureBytes,
                )
                val proof = JSONObject()
                    .put("challenge_id", Base64.encodeToString(challengeId, Base64.NO_WRAP))
                    .put("signature", Base64.encodeToString(signatureBytes, Base64.NO_WRAP))
                    .toString()
                    .toByteArray(Charsets.UTF_8)
                sendEncrypted(
                    socket,
                    serverAddr,
                    PKT_AUTH_PROOF,
                    proof,
                    proofKeyVersion,
                    proofAuthKey,
                )

                val result = receiveAuthenticatedPacket(socket)
                when (result.type) {
                    PKT_AUTH_OK -> return parseAuthOk(result.payload, sessionKeys)
                    PKT_AUTH_DENY -> throw AuthDeniedException(parseAuthDenial(result.payload))
                    else -> throw IllegalStateException("Expected AUTH_OK or AUTH_DENY")
                }
            } catch (e: AuthDeniedException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Authentication attempt ${attempt + 1} failed: ${e.javaClass.simpleName}")
                if (attempt + 1 < AUTH_MAX_ATTEMPTS) Thread.sleep(AUTH_RETRY_DELAY_MS)
            } finally {
                challengeId?.fill(0)
                challenge?.fill(0)
            }
        }
        throw IllegalStateException("Authentication failed")
    }

    private fun parseAuthOk(payload: ByteArray, sessionKeys: DataSessionKeys): AuthResult {
        val json = JSONObject(payload.toString(Charsets.UTF_8))
        val status = json.requireString("status")
        require(status == "OK") { "Malformed AUTH_OK status" }

        val tunnelIp = json.requireString("tunnel_ip")
        requireValidTunnelIp(tunnelIp)
        val tunnelIpBytes = parseIpv4Address(tunnelIp)

        val prefixLength = json.requireInt("prefix_length")
        require(prefixLength == 24) { "Malformed AUTH_OK prefix length" }

        val mtu = json.requireInt("mtu")
        require(mtu in 576..1500) { "Malformed AUTH_OK MTU" }
        val updateNotice = if (json.optBoolean("update_available", false)) {
            UpdateNotice(
                latestVersion = json.optString("latest_version").takeIf { it.isNotBlank() },
                updateUrl = json.optString("update_url").takeIf { it.isNotBlank() },
            )
        } else {
            null
        }

        return AuthResult(
            tunnelIp = tunnelIp,
            tunnelIpBytes = tunnelIpBytes,
            prefixLength = prefixLength,
            mtu = mtu,
            updateNotice = updateNotice,
            sessionKeyVersion = sessionKeys.keyVersion,
            clientToServerDataKey = sessionKeys.clientToServer,
            serverToClientDataKey = sessionKeys.serverToClient,
        )
    }

    private fun JSONObject.requireString(name: String): String {
        require(has(name)) { "Missing AUTH_OK field: $name" }
        val value = get(name)
        require(value is String) { "Malformed AUTH_OK field: $name" }
        return value
    }

    private fun JSONObject.requireInt(name: String): Int {
        require(has(name)) { "Missing AUTH_OK field: $name" }
        val value = get(name)
        require(value is Int) { "Malformed AUTH_OK field: $name" }
        return value
    }

    private fun requireValidTunnelIp(tunnelIp: String) {
        val octets = tunnelIp.split(".")
        require(octets.size == 4) { "Malformed AUTH_OK tunnel_ip" }

        val values = octets.map { octet ->
            require(octet.isNotEmpty() && octet.all(Char::isDigit)) {
                "Malformed AUTH_OK tunnel_ip"
            }
            require(octet == "0" || !octet.startsWith("0")) {
                "Malformed AUTH_OK tunnel_ip"
            }
            octet.toInt().also {
                require(it in 0..255) { "Malformed AUTH_OK tunnel_ip" }
            }
        }

        require(values[0] == 10 && values[1] == 1 && values[2] == 0) {
            "AUTH_OK tunnel_ip outside 10.1.0.0/24"
        }
        require(values[3] !in setOf(0, 1, 255)) {
            "AUTH_OK tunnel_ip is reserved"
        }
    }

    private fun requireValidPublicIdentity() {
        require(deviceId.matches(Regex("[0-9a-f]{64}"))) { "Invalid device ID" }
        val publicKeyBytes = Base64.decode(publicKey, Base64.DEFAULT)
        require(publicKeyBytes.size == 32) {
            "Invalid Ed25519 public key"
        }
        val expectedDeviceId = MessageDigest.getInstance("SHA-256")
            .digest(publicKeyBytes)
            .joinToString("") { "%02x".format(it) }
        require(deviceId == expectedDeviceId) { "Device identity mismatch" }
    }

    private fun sendEncrypted(
        socket: DatagramSocket,
        serverAddr: InetAddress,
        type: Byte,
        payload: ByteArray,
        keyVersion: Byte? = null,
        key: ByteArray? = null,
    ) {
        val packet = if (keyVersion != null && key != null) {
            VpnConfig.encryptPacketWithKey(type, keyVersion, key, payload)
        } else {
            VpnConfig.encryptPacket(type, payload)
        }
        socket.send(DatagramPacket(packet, packet.size, serverAddr, VpnConfig.SERVER_PORT))
    }

    private fun receiveAuthenticatedPacket(socket: DatagramSocket): VpnConfig.AuthPacket {
        val deadline = System.currentTimeMillis() + AUTH_PACKET_TIMEOUT_MS
        val buffer = ByteArray(VpnConfig.MAX_UDP_PACKET_SIZE)
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) throw SocketTimeoutException("Authentication timed out")
            socket.soTimeout = remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            val reply = DatagramPacket(buffer, buffer.size)
            socket.receive(reply)
            val authenticated = VpnConfig.decryptAuthPacket(buffer.copyOf(reply.length))
            if (authenticated != null) return authenticated
        }
    }

    private fun deriveDataSessionKeys(
        keyVersion: Byte,
        authKey: ByteArray,
        challengeId: ByteArray,
        challenge: ByteArray,
        publicKeyBytes: ByteArray,
        appVersion: String,
        platform: String,
        signatureBytes: ByteArray,
    ): DataSessionKeys {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("xor-vpn-auth-v1".toByteArray(Charsets.UTF_8))
        digest.update(challengeId)
        digest.update(challenge)
        digest.update(deviceId.toByteArray(Charsets.UTF_8))
        digest.update(publicKeyBytes)
        if (appVersion.isNotEmpty() || platform.isNotEmpty()) {
            digest.update(appVersion.toByteArray(Charsets.UTF_8))
            digest.update(platform.toByteArray(Charsets.UTF_8))
        }
        digest.update(signatureBytes)
        val transcriptHash = digest.digest()
        return DataSessionKeys(
            keyVersion = keyVersion,
            clientToServer = VpnConfig.deriveSessionKey(
                authKey,
                transcriptHash,
                "session-data-client-to-server",
            ),
            serverToClient = VpnConfig.deriveSessionKey(
                authKey,
                transcriptHash,
                "session-data-server-to-client",
            ),
        )
    }

    private fun hasAssignedIpv4Source(packet: ByteArray, tunnelIpBytes: ByteArray): Boolean {
        if (packet.size < 20 || ((packet[0].toInt() and 0xF0) ushr 4) != 4) return false
        return packet[12] == tunnelIpBytes[0] &&
            packet[13] == tunnelIpBytes[1] &&
            packet[14] == tunnelIpBytes[2] &&
            packet[15] == tunnelIpBytes[3]
    }

    private fun parseIpv4Address(ip: String): ByteArray =
        ip.split(".").map { it.toInt().toByte() }.toByteArray()

    private fun requestSignature(challengeId: ByteArray, challenge: ByteArray): String {
        val channel = flutterChannel ?: error("Flutter authentication channel unavailable")
        val latch = CountDownLatch(1)
        val signature = AtomicReference<String?>()
        val failure = AtomicReference<String?>()
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            channel.invokeMethod(
                "signAuthChallenge",
                mapOf(
                    "buildNumber" to buildNumber,
                    "appVersion" to appVersion,
                    "platform" to platform,
                    "challengeId" to Base64.encodeToString(challengeId, Base64.NO_WRAP),
                    "challenge" to Base64.encodeToString(challenge, Base64.NO_WRAP),
                ),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        signature.set(result as? String)
                        latch.countDown()
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        failure.set(code)
                        latch.countDown()
                    }

                    override fun notImplemented() {
                        failure.set("not_implemented")
                        latch.countDown()
                    }
                },
            )
        }
        if (!latch.await(SIGNING_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            throw SocketTimeoutException("Signing timed out")
        }
        failure.get()?.let { error("Signing failed: $it") }
        return signature.get() ?: error("Signing returned no signature")
    }

    private fun parseAuthDenial(payload: ByteArray): AuthDenial {
        val text = payload.toString(Charsets.UTF_8).trim()
        val json = runCatching { JSONObject(text) }.getOrNull()
        if (json != null) {
            return AuthDenial(
                reason = json.optString("reason").takeIf { it.isNotBlank() } ?: "denied",
                minVersion = json.optString("min_version").takeIf { it.isNotBlank() },
                latestVersion = json.optString("latest_version").takeIf { it.isNotBlank() },
                updateUrl = json.optString("update_url").takeIf { it.isNotBlank() },
                updateAvailable = json.optBoolean("update_available", false),
            )
        }
        return AuthDenial(
            reason = text.ifBlank { "denied" },
            minVersion = null,
            latestVersion = null,
            updateUrl = null,
            updateAvailable = false,
        )
    }

    private fun addAllowedTargetApps(builder: Builder): Int {
        var count = 0
        for (packageName in targetPackages) {
            try {
                builder.addAllowedApplication(packageName)
                count++
                Log.d(TAG, "Routing $packageName through the VPN")
            } catch (_: PackageManager.NameNotFoundException) {
                Log.d(TAG, "Target app is not installed: $packageName")
            }
        }
        return count
    }

    // -----------------------------------------------------------------------
    // Stop
    // -----------------------------------------------------------------------

    private fun stopVpn() {
        if (!running && vpnInterface == null && udpSocket == null) {
            clearAssignedAuthResult()
            return
        }

        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null
        clearAssignedAuthResult()
        running = false
        try { udpSocket?.close() } catch (_: Exception) {}
        udpSocket = null

        // Remove the foreground notification (API-safe for all versions we target)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(true)
        }

        // Tell Flutter the VPN is fully gone so it can update the UI
        notify("disconnected")

        stopSelf()
    }

    private fun clearAssignedAuthResult() {
        val assignedTunnelIp = assignedAuthResult?.tunnelIp
        assignedAuthResult = null
        if (assignedTunnelIp != null) {
            Log.d(TAG, "Cleared server-assigned tunnel address")
        }
    }

    // -----------------------------------------------------------------------
    // Push status string to Flutter UI via MethodChannel
    // -----------------------------------------------------------------------

    private fun notify(status: String) {
        Log.d(TAG, "Status → $status")
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            flutterChannel?.invokeMethod("onStatusChange", status)
        }
    }

    // -----------------------------------------------------------------------
    // Foreground notification
    // -----------------------------------------------------------------------

    private fun startForegroundNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(NOTIF_CHANNEL, "VPN Tunnel",
                NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }

        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, XorVpnService::class.java).apply { action = "STOP" },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notif = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIF_CHANNEL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
            .setContentTitle("XorVPN Active")
            .setContentText("Selected app traffic is protected")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .addAction(android.R.drawable.ic_delete, "Disconnect", stopIntent)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }
}
