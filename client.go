package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/songgao/water"
)

func main() {

	config := water.Config{DeviceType: water.TUN}
	config.Name = "tun0"

	ifce, err := water.New(config)
	if err != nil {
		log.Fatalf("Fatal: Failed to create TUN interface: %v", err)
	}
	defer ifce.Close()

	fmt.Printf("[*] Client TUN Interface Created: %s\n", ifce.Name())
	fmt.Println("[*] Set up your local system routes to point traffic here.")

	serverAddr := "IPIPIPIPIPIPIP:PORTPORTPORTPORT" 
	udpRemoteAddr, _ := net.ResolveUDPAddr("udp", serverAddr)
	udpConn, err := net.DialUDP("udp", nil, udpRemoteAddr)
	if err != nil {
		log.Fatalf("Failed to connect to remote server: %v", err)
	}
	defer udpConn.Close()

	// Handle graceful shutdown (Ctrl+C)
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		fmt.Println("\n[*] Shutting down client safely...")
		ifce.Close()
		os.Exit(0)
	}()

	packetBuffer := make([]byte, 1500) // Standard MTU size


	for {
		n, err := ifce.Read(packetBuffer)
		if err != nil {
			break
		}
		rawPacket := packetBuffer[:n]


		fmt.Printf("[Capturing] Raw IP Packet intercepted from OS (%d bytes)\n", n)

		ObfuscateXOR(rawPacket, CryptoKey)

		ObfuscateXOR(rawPacket, ObfuscateKey)

		_, err = udpConn.Write(rawPacket)
		if err != nil {
			log.Printf("Write error: %v", err)
		}
	}
}