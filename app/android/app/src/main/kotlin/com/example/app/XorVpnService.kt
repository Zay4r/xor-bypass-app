package com.example.app

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.io.FileInputStream
import java.io.FileOutputStream

class XorVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null
    private var running = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            stopVpn()
            return START_NOT_STICKY
        }
        Thread { startVpn() }.start()
        return START_STICKY
    }

    private fun startVpn() {
        val builder = Builder()
        builder.addAddress(VpnConfig.TUNNEL_IP, VpnConfig.TUNNEL_PREFIX)
        builder.addDnsServer(VpnConfig.DNS_SERVER)
        builder.addRoute("0.0.0.0", 0) // All Autobots
        builder.allowFamily(android.system.OsConstants.AF_INET)
        builder.setSession(VpnConfig.SESSION_NAME)
        builder.setMtu(VpnConfig.MTU)
        vpnInterface = builder.establish() ?: return

        running = true

        val udpSocket = DatagramSocket()
        protect(udpSocket)
        val serverAddr = InetAddress.getByName(VpnConfig.SERVER_IP)

        // Send: phone -> encrypt -> SERVER
        Thread {
            val buffer = ByteArray(1500)
            val input = FileInputStream(vpnInterface!!.fileDescriptor)
            while (running) {
                try {
                    val n = input.read(buffer)
                    if (n <= 0) continue
                    val packet = buffer.copyOf(n)
                    VpnConfig.xorObfuscate(packet, VpnConfig.CRYPTO_KEY)
                    VpnConfig.xorObfuscate(packet, VpnConfig.OBFUSCATE_KEY)
                    udpSocket.send(DatagramPacket(packet, packet.size, serverAddr, VpnConfig.SERVER_PORT))
                } catch (e: Exception) {}
            }
        }.start()

        // Receive: SERVER -> decrypt -> phone
        Thread {
            val buffer = ByteArray(1500)
            val output = FileOutputStream(vpnInterface!!.fileDescriptor)
            val udpPacket = DatagramPacket(buffer, buffer.size)
            while (running) {
                try {
                    udpSocket.receive(udpPacket)
                    val data = buffer.copyOf(udpPacket.length)
                    VpnConfig.xorObfuscate(data, VpnConfig.OBFUSCATE_KEY)
                    VpnConfig.xorObfuscate(data, VpnConfig.CRYPTO_KEY)
                    output.write(data)
                } catch (e: Exception) {}
            }
        }.start()
    }

    private fun stopVpn() {
        running = false
        vpnInterface?.close()
        vpnInterface = null
        stopSelf()
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }
}