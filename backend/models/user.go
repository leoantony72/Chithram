package models

import "gorm.io/gorm"

type User struct {
	gorm.Model
	Username string `json:"username" gorm:"unique"`
	Email    string `json:"email" gorm:"unique"`
	Password string `json:"password"` // Authenticating password hash (bcrypt)

	// Key Derivation Parameters
	KEKSalt string `json:"kek_salt"` // stored base64

	// Encrypted Master Key Data
	EncryptedMasterKey string `json:"encrypted_master_key"` // Stored on server, decrypted by KEK
	MasterKeyNonce     string `json:"master_key_nonce"`     // Nonce for master key encryption

	// Public Key Data (Publicly accessible/verifiable)
	PublicKey string `json:"public_key"`

	// Encrypted Private Key Data
	EncryptedPrivateKey string `json:"encrypted_private_key"` // Stored on server, decrypted by MasterKey
	PrivateKeyNonce     string `json:"private_key_nonce"`     // Nonce for private key encryption
}
