package com.example.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import android.content.pm.ServiceInfo
import android.os.Build

private const val TAG           = "XorVpnService"
private const val NOTIF_CHANNEL = "xor_vpn"
private const val NOTIF_ID      = 1

// Packet type constants — must match server Crypto.go exactly
private const val PKT_AUTH      = 0x01.toByte()
private const val PKT_DATA      = 0x02.toByte()
private const val PKT_AUTH_OK   = 0xA0.toByte()
private const val PKT_AUTH_DENY = 0xA1.toByte()

class XorVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var running      = false

    // Device build number
    private var buildNumber = ""

    companion object {
        var flutterChannel: MethodChannel? = null
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            stopVpn()
            return START_NOT_STICKY
        }
        buildNumber = intent?.getStringExtra("buildNumber") ?: Build.FINGERPRINT
        startForegroundNotification()
        Thread { startVpn() }.start()
        return START_STICKY
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
            udpSocket!!.soTimeout = 10_000
            if (!performAuth(socket, serverAddr)) {
                notify("denied")
                stopVpn()
                return
            }
            udpSocket!!.soTimeout = 0

            // ── Step 2: Build TUN interface ────────────────────────────────
            val builder = Builder()
            builder.addAddress(VpnConfig.TUNNEL_IP, VpnConfig.TUNNEL_PREFIX)
            builder.addDnsServer(VpnConfig.DNS_SERVER)
            builder.addRoute("0.0.0.0", 0)
            builder.allowFamily(android.system.OsConstants.AF_INET)
            builder.setSession(VpnConfig.SESSION_NAME)
            builder.setMtu(VpnConfig.MTU)

            vpnInterface = builder.establish() ?: run {
                notify("error: VPN permission not granted")
                return
            }

            running = true
            notify("connected")

            // ── Step 3: phone → encrypt → server ──────────────────────────
            Thread {
                val sock   = udpSocket ?: return@Thread
                val buffer = ByteArray(VpnConfig.MTU)
                val input  = FileInputStream(vpnInterface!!.fileDescriptor)
                while (running) {
                    try {
                        val n = input.read(buffer)
                        if (n <= 0) continue

                        val wrapped = encodePacket(PKT_DATA, buffer.copyOf(n))
                        VpnConfig.xorObfuscate(wrapped, VpnConfig.CRYPTO_KEY)
                        VpnConfig.xorObfuscate(wrapped, VpnConfig.OBFUSCATE_KEY)

                        sock.send(DatagramPacket(wrapped, wrapped.size, serverAddr, VpnConfig.SERVER_PORT))
                    } catch (e: Exception) {
                        if (running) Log.w(TAG, "Send error: ${e.message}")
                    }
                }
            }.start()

            // ── Step 4: server → decrypt → phone ──────────────────────────
            // Also handles mid-session PKT_AUTH_DENY kick from the server.
            Thread {
                val sock      = udpSocket ?: return@Thread   // snapshot — safe from concurrent null
                val buffer    = ByteArray(VpnConfig.MTU + 4)
                val output    = FileOutputStream(vpnInterface!!.fileDescriptor)
                val udpPacket = DatagramPacket(buffer, buffer.size)
                while (running) {
                    try {
                        sock.receive(udpPacket)
                        val raw = buffer.copyOf(udpPacket.length)

                        VpnConfig.xorObfuscate(raw, VpnConfig.OBFUSCATE_KEY)
                        VpnConfig.xorObfuscate(raw, VpnConfig.CRYPTO_KEY)

                        val (type, payload) = decodePacket(raw) ?: continue

                        when (type) {
                            PKT_DATA -> {
                                // Normal tunnel traffic — write to TUN
                                output.write(payload)
                            }

                            PKT_AUTH_DENY -> {
                                // Server kicked us mid-session (blocked or expired).
                                val reason = payload.toString(Charsets.UTF_8).trim()
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
        }
    }

    // -----------------------------------------------------------------------
    // Auth handshake
    // -----------------------------------------------------------------------

    private fun performAuth(socket: DatagramSocket, serverAddr: InetAddress): Boolean {
        val authPkt = encodePacket(PKT_AUTH, buildNumber.toByteArray(Charsets.UTF_8))
        VpnConfig.xorObfuscate(authPkt, VpnConfig.CRYPTO_KEY)
        VpnConfig.xorObfuscate(authPkt, VpnConfig.OBFUSCATE_KEY)

        val recvBuf = ByteArray(64)

        repeat(3) { attempt ->
            Log.d(TAG, "Auth attempt ${attempt + 1}/3  build=$buildNumber")
            try {
                socket.send(DatagramPacket(authPkt, authPkt.size, serverAddr, VpnConfig.SERVER_PORT))

                val reply = DatagramPacket(recvBuf, recvBuf.size)
                socket.receive(reply)

                val raw = recvBuf.copyOf(reply.length)
                VpnConfig.xorObfuscate(raw, VpnConfig.OBFUSCATE_KEY)
                VpnConfig.xorObfuscate(raw, VpnConfig.CRYPTO_KEY)

                val (type, _) = decodePacket(raw) ?: return@repeat
                return when (type) {
                    PKT_AUTH_OK   -> { Log.d(TAG, "Auth OK"); true }
                    PKT_AUTH_DENY -> { Log.w(TAG, "Auth DENIED — trial expired or blocked"); false }
                    else          -> { Log.w(TAG, "Unknown auth response 0x${type.toString(16)}"); false }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Auth attempt ${attempt + 1} failed: ${e.message}")
                Thread.sleep(2_000)
            }
        }
        Log.e(TAG, "All auth attempts exhausted")
        return false
    }

    // -----------------------------------------------------------------------
    // Packet framing helpers
    // -----------------------------------------------------------------------

    private fun encodePacket(type: Byte, payload: ByteArray): ByteArray {
        val out = ByteArray(1 + payload.size)
        out[0] = type
        payload.copyInto(out, destinationOffset = 1)
        return out
    }

    private fun decodePacket(data: ByteArray): Pair<Byte, ByteArray>? {
        if (data.isEmpty()) return null
        return Pair(data[0], data.sliceArray(1 until data.size))
    }

    // -----------------------------------------------------------------------
    // Stop
    // -----------------------------------------------------------------------

    private fun stopVpn() {
        if (!running && vpnInterface == null) return   // already stopped, avoid double-call
        running = false

        // Close the UDP socket first — this unblocks any receive() call in the
        // recv thread so it exits cleanly instead of hanging forever.
        try { udpSocket?.close() } catch (_: Exception) {}
        udpSocket = null

        // Close the TUN file descriptor — this tears down the virtual interface
        // and restores normal Android routing immediately.
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

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
            .setContentText("Tunnel is running")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .addAction(android.R.drawable.ic_delete, "Disconnect", stopIntent)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notif, 0x40000000.toInt())
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }
}