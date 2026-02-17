package controllers

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"

	"chithram/database"
	"chithram/models"
)

type SignupInput struct {
	Email               string `json:"email" binding:"required"`
	Password            string `json:"password" binding:"required"`
	KEKSalt             string `json:"kek_salt" binding:"required"`
	EncryptedMasterKey  string `json:"encrypted_master_key" binding:"required"`
	MasterKeyNonce      string `json:"master_key_nonce" binding:"required"`
	PublicKey           string `json:"public_key" binding:"required"`
	EncryptedPrivateKey string `json:"encrypted_private_key" binding:"required"`
	PrivateKeyNonce     string `json:"private_key_nonce" binding:"required"`
}

type LoginInput struct {
	Email    string `json:"email" binding:"required"`
	Password string `json:"password" binding:"required"`
}

func Signup(c *gin.Context) {
	var input SignupInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to hash password"})
		return
	}

	user := models.User{
		Email:               input.Email,
		Password:            string(hashedPassword),
		KEKSalt:             input.KEKSalt,
		EncryptedMasterKey:  input.EncryptedMasterKey,
		MasterKeyNonce:      input.MasterKeyNonce,
		PublicKey:           input.PublicKey,
		EncryptedPrivateKey: input.EncryptedPrivateKey,
		PrivateKeyNonce:     input.PrivateKeyNonce,
	}

	if err := database.DB.Create(&user).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Could not create user"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "User created successfully"})
}

func Login(c *gin.Context) {
	var input LoginInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var user models.User
	if err := database.DB.Where("email = ?", input.Email).First(&user).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid credentials"})
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.Password), []byte(input.Password)); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid credentials"})
		return
	}

	// In a real app, generate a JWT token here. For this demo, we return the encryption blobs immediately.
	c.JSON(http.StatusOK, gin.H{
		"email":                 user.Email,
		"kek_salt":              user.KEKSalt,
		"encrypted_master_key":  user.EncryptedMasterKey,
		"master_key_nonce":      user.MasterKeyNonce,
		"public_key":            user.PublicKey,
		"encrypted_private_key": user.EncryptedPrivateKey,
		"private_key_nonce":     user.PrivateKeyNonce,
	})
}
