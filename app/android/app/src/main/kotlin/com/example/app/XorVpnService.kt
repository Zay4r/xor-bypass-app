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
    val prefixLength: Int,
    val mtu: Int,
)

private class AuthDeniedException(val reason: String) : Exception(reason)

class XorVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var running = false
    private var buildNumber = ""
    private var deviceId = ""
    private var publicKey = ""
    private val startLock = Any()
    private var handshakeInProgress = false
    private var assignedAuthResult: AuthResult? = null

    companion object {
        var flutterChannel: MethodChannel? = null

        private const val AUTH_MAX_ATTEMPTS = 3
        private const val AUTH_PACKET_TIMEOUT_MS = 5_000L
        private const val SIGNING_TIMEOUT_MS = 5_000L
        private const val AUTH_RETRY_DELAY_MS = 1_000L

        private val TARGET_PACKAGES = listOf(
            "com.facebook.katana",
            "com.facebook.lite",
            "com.facebook.orca",
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
        deviceId = intent?.getStringExtra("deviceId").orEmpty()
        publicKey = intent?.getStringExtra("publicKey").orEmpty()
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
                notify("denied:${e.reason}")
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
                notify("error: Facebook is not installed")
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

            // ── Step 3: phone → encrypt → server ──────────────────────────
            Thread {
                val sock = udpSocket ?: return@Thread
                val buffer = ByteArray(authResult.mtu)
                val input = FileInputStream(vpnInterface!!.fileDescriptor)
                while (running) {
                    try {
                        val n = input.read(buffer)
                        if (n <= 0) continue

                        val wrapped = VpnConfig.encryptPacket(PKT_DATA, buffer.copyOf(n))

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
                        val (type, payload) = VpnConfig.decryptPacket(raw) ?: continue

                        when (type) {
                            PKT_DATA -> {
                                // Normal tunnel traffic — write to TUN
                                output.write(payload)
                            }

                            PKT_AUTH_DENY -> {
                                // Server kicked us mid-session (blocked or expired).
                                val reason = denialReason(payload)
                                Log.w(TAG, "Mid-session kick received — reason: $reason")
                                // notify Flutter first, then tear down everything via stopVpn()
                                notify("denied:$reason")
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
            deviceId = ""
            publicKey = ""
        }
    }

    // -----------------------------------------------------------------------
    // Auth handshake
    // -----------------------------------------------------------------------

    private fun performAuth(socket: DatagramSocket, serverAddr: InetAddress): AuthResult {
        requireValidPublicIdentity()
        val hello = JSONObject()
            .put("build_number", buildNumber)
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
                if (challengePacket.first == PKT_AUTH_DENY) {
                    throw AuthDeniedException(denialReason(challengePacket.second))
                }
                if (challengePacket.first != PKT_AUTH_CHALLENGE) {
                    throw IllegalStateException("Expected AUTH_CHALLENGE")
                }

                val challengeJson = JSONObject(challengePacket.second.toString(Charsets.UTF_8))
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
                val proof = JSONObject()
                    .put("challenge_id", Base64.encodeToString(challengeId, Base64.NO_WRAP))
                    .put("signature", Base64.encodeToString(signatureBytes, Base64.NO_WRAP))
                    .toString()
                    .toByteArray(Charsets.UTF_8)
                sendEncrypted(socket, serverAddr, PKT_AUTH_PROOF, proof)

                val result = receiveAuthenticatedPacket(socket)
                when (result.first) {
                    PKT_AUTH_OK -> return parseAuthOk(result.second)
                    PKT_AUTH_DENY -> throw AuthDeniedException(denialReason(result.second))
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

    private fun parseAuthOk(payload: ByteArray): AuthResult {
        val json = JSONObject(payload.toString(Charsets.UTF_8))
        val status = json.requireString("status")
        require(status == "OK") { "Malformed AUTH_OK status" }

        val tunnelIp = json.requireString("tunnel_ip")
        requireValidTunnelIp(tunnelIp)

        val prefixLength = json.requireInt("prefix_length")
        require(prefixLength == 24) { "Malformed AUTH_OK prefix length" }

        val mtu = json.requireInt("mtu")
        require(mtu in 576..1500) { "Malformed AUTH_OK MTU" }

        return AuthResult(
            tunnelIp = tunnelIp,
            prefixLength = prefixLength,
            mtu = mtu,
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
    ) {
        val packet = VpnConfig.encryptPacket(type, payload)
        socket.send(DatagramPacket(packet, packet.size, serverAddr, VpnConfig.SERVER_PORT))
    }

    private fun receiveAuthenticatedPacket(socket: DatagramSocket): Pair<Byte, ByteArray> {
        val deadline = System.currentTimeMillis() + AUTH_PACKET_TIMEOUT_MS
        val buffer = ByteArray(VpnConfig.MAX_UDP_PACKET_SIZE)
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) throw SocketTimeoutException("Authentication timed out")
            socket.soTimeout = remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            val reply = DatagramPacket(buffer, buffer.size)
            socket.receive(reply)
            val authenticated = VpnConfig.decryptPacket(buffer.copyOf(reply.length))
            if (authenticated != null) return authenticated
        }
    }

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

    private fun denialReason(payload: ByteArray): String {
        val text = payload.toString(Charsets.UTF_8).trim()
        val parsed = runCatching { JSONObject(text).optString("reason") }.getOrNull()
        return (parsed?.takeIf { it.isNotBlank() } ?: text).ifBlank { "denied" }
    }

    private fun addAllowedTargetApps(builder: Builder): Int {
        var count = 0
        for (packageName in TARGET_PACKAGES) {
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
            .setContentText("Facebook traffic is protected")
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
