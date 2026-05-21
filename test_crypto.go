package main

import (
	"fmt"
	"bytes"
)

func main() {
	// --- SIMULATE a raw IP packet (normally captured from TUN interface)
	// In real client.go, this comes from: ifce.Read(packetBuffer)
	originalPacket := []byte("GET / HTTP/1.1\r\nHost: google.com\r\n\r\n")

	fmt.Println("=== ORIGINAL PACKET ===")
	fmt.Printf("Text : %s\n", originalPacket)
	fmt.Printf("Bytes: %v\n\n", originalPacket)

	// --- Make a copy to work on (so we keep the original for comparison)
	workingCopy := make([]byte, len(originalPacket))
	copy(workingCopy, originalPacket)

	// --- LAYER 1: Encrypt with CryptoKey
	ObfuscateXOR(workingCopy, CryptoKey)
	fmt.Println("=== AFTER LAYER 1 (Encrypted with CryptoKey) ===")
	fmt.Printf("Bytes: %v\n\n", workingCopy)

	// --- LAYER 2: Obfuscate with ObfuscateKey (hides DPI fingerprint)
	ObfuscateXOR(workingCopy, ObfuscateKey)
	fmt.Println("=== AFTER LAYER 2 (Obfuscated - what actually travels over internet) ===")
	fmt.Printf("Bytes: %v\n\n", workingCopy)

	// --- Now REVERSE it (this is what server.go does on the other end)
	// Reverse Layer 2 first
	ObfuscateXOR(workingCopy, ObfuscateKey)
	fmt.Println("=== AFTER REVERSING LAYER 2 ===")
	fmt.Printf("Bytes: %v\n\n", workingCopy)

	// Reverse Layer 1
	ObfuscateXOR(workingCopy, CryptoKey)
	fmt.Println("=== AFTER REVERSING LAYER 1 (Fully Decrypted) ===")
	fmt.Printf("Text : %s\n", workingCopy)
	fmt.Printf("Bytes: %v\n\n", workingCopy)

	// --- VERIFY original matches decrypted
	if bytes.Equal(originalPacket, workingCopy) {
		fmt.Println("✅ SUCCESS: Decrypted packet matches original exactly!")
	} else {
		fmt.Println("❌ FAIL: Something went wrong")
	}
}