package main

//
// Just educational Function for XOR layer 2 way turn around
//

var (
	CryptoKey    = []byte("CryptoKeyCryptoKeyCryptoKeyCryptoKey") 
	ObfuscateKey = []byte("ObfuscateKeyObfuscateKeyObfuscateKey") 
)

// ObfuscateXOR scrambles/unscrambles the byte payload in-place using a multi-byte rolling key.
// Because XOR is symmetrical, running a byte through this function twice restores it.
func ObfuscateXOR(data []byte, key []byte) {
	if len(key) == 0 {
		return
	}
	for i := 0; i < len(data); i++ {
		data[i] ^= key[i% len(key)]
	}
}