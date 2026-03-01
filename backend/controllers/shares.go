package controllers

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"chithram/database"
	"chithram/models"
	"chithram/services"
)

// ShareCreateInput for creating a share
type ShareCreateInput struct {
	ReceiverUsername  string `json:"receiver_username" binding:"required"`
	ImageID           string `json:"image_id" binding:"required"`
	ShareType         string `json:"share_type" binding:"required"` // one_time | normal
	EncryptedShareKey string `json:"encrypted_share_key"`           // base64, share_key encrypted for receiver
	SenderPublicKey   string `json:"sender_public_key"`             // base64, for receiver to decrypt
}

// CreateShare creates a new share (sender uploads encrypted image to shares/; this endpoint just creates the DB record)
// Client flow: 1) Get upload URL from backend 2) Upload encrypted image 3) Call this with share metadata
func CreateShare(c *gin.Context) {
	senderID := c.Query("user_id")
	if senderID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id required"})
		return
	}

	var input ShareCreateInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if input.ShareType != models.ShareTypeOneTime && input.ShareType != models.ShareTypeNormal {
		c.JSON(http.StatusBadRequest, gin.H{"error": "share_type must be one_time or normal"})
		return
	}

	// Verify receiver exists
	var receiver models.User
	if err := database.DB.Where("username = ?", input.ReceiverUsername).First(&receiver).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "Receiver user not found"})
		return
	}

	if receiver.Username == senderID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Cannot share with yourself"})
		return
	}

	// Verify sender owns the image
	var img models.Image
	if err := database.DB.Where("image_id = ? AND user_id = ? AND is_deleted = ?", input.ImageID, senderID, false).First(&img).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "Image not found or you don't own it"})
		return
	}

	shareID := uuid.New().String()
	share := models.Share{
		ID:                shareID,
		SenderID:          senderID,
		ReceiverID:        receiver.Username,
		ImageID:           input.ImageID,
		ShareType:         input.ShareType,
		EncryptedShareKey: input.EncryptedShareKey,
		SenderPublicKey:   input.SenderPublicKey,
		CreatedAt:         time.Now(),
	}

	if err := database.DB.Create(&share).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to create share"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"share_id":   shareID,
		"created_at": share.CreatedAt,
	})
}

// GetShareUploadURL returns a presigned PUT URL for uploading the shared (re-encrypted) image
func GetShareUploadURL(c *gin.Context) {
	shareID := c.Param("id")
	userID := c.Query("user_id")
	if userID == "" || shareID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "id and user_id required"})
		return
	}

	// Verify share exists and user is sender
	var share models.Share
	if err := database.DB.Where("id = ? AND sender_id = ?", shareID, userID).First(&share).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "Share not found"})
		return
	}

	objectName := "shares/" + shareID + ".enc"
	url, err := services.GetPresignedPutURL(objectName, 15*time.Minute)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to generate upload URL"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"upload_url": url})
}

// ListSharesWithMe returns shares where current user is receiver
func ListSharesWithMe(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id required"})
		return
	}

	var shares []models.Share
	if err := database.DB.Where("receiver_id = ?", userID).Order("created_at DESC").Find(&shares).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to list shares"})
		return
	}

	// Enrich with sender info and image metadata
	type ShareWithSender struct {
		models.Share
		SenderUsername string `json:"sender_username"`
		Width          int    `json:"width"`
		Height         int    `json:"height"`
		MimeType       string `json:"mime_type"`
	}

	result := make([]ShareWithSender, 0, len(shares))
	for _, s := range shares {
		sws := ShareWithSender{Share: s, SenderUsername: s.SenderID}
		var img models.Image
		if err := database.DB.Where("image_id = ? AND user_id = ?", s.ImageID, s.SenderID).First(&img).Error; err == nil {
			sws.Width = img.Width
			sws.Height = img.Height
			sws.MimeType = img.MimeType
		}
		result = append(result, sws)
	}

	c.JSON(http.StatusOK, gin.H{"shares": result})
}

// ListSharesByMe returns shares where current user is sender
func ListSharesByMe(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id required"})
		return
	}

	var shares []models.Share
	if err := database.DB.Where("sender_id = ?", userID).Order("created_at DESC").Find(&shares).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to list shares"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"shares": shares})
}

// GetShare returns share metadata for receiver (includes keys for decryption)
func GetShare(c *gin.Context) {
	shareID := c.Param("id")
	userID := c.Query("user_id")
	if userID == "" || shareID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "id and user_id required"})
		return
	}

	var share models.Share
	if err := database.DB.Where("id = ? AND receiver_id = ?", shareID, userID).First(&share).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "Share not found"})
		return
	}

	// For one_time, check if already viewed
	if share.ShareType == models.ShareTypeOneTime && share.ViewedAt != nil {
		c.JSON(http.StatusGone, gin.H{"error": "This share was one-time and has already been viewed"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"share_id":            share.ID,
		"sender_id":           share.SenderID,
		"image_id":            share.ImageID,
		"share_type":          share.ShareType,
		"encrypted_share_key": share.EncryptedShareKey,
		"sender_public_key":   share.SenderPublicKey,
		"created_at":          share.CreatedAt,
	})
}

// GetShareDownloadURL returns presigned GET URL for the shared image
func GetShareDownloadURL(c *gin.Context) {
	shareID := c.Param("id")
	userID := c.Query("user_id")
	if userID == "" || shareID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "id and user_id required"})
		return
	}

	var share models.Share
	if err := database.DB.Where("id = ? AND receiver_id = ?", shareID, userID).First(&share).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "Share not found"})
		return
	}

	// For one_time, check if already viewed
	if share.ShareType == models.ShareTypeOneTime && share.ViewedAt != nil {
		c.JSON(http.StatusGone, gin.H{"error": "This share was one-time and has already been viewed"})
		return
	}

	objectName := "shares/" + shareID + ".enc"
	url, err := services.GetPresignedURL(objectName, 15*time.Minute)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to generate download URL"})
		return
	}

	// Mark as viewed for one_time
	if share.ShareType == models.ShareTypeOneTime {
		now := time.Now()
		database.DB.Model(&share).Update("viewed_at", now)
	}

	c.JSON(http.StatusOK, gin.H{
		"download_url": url,
		"sender_id":    share.SenderID,
		"image_id":     share.ImageID,
	})
}

// RevokeShare allows sender to revoke a share
func RevokeShare(c *gin.Context) {
	shareID := c.Param("id")
	userID := c.Query("user_id")
	if userID == "" || shareID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "id and user_id required"})
		return
	}

	result := database.DB.Where("id = ? AND sender_id = ?", shareID, userID).Delete(&models.Share{})
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "Share not found"})
		return
	}

	// Optionally delete the object from MinIO
	objectName := "shares/" + shareID + ".enc"
	_ = services.DeleteObject(objectName)

	c.JSON(http.StatusOK, gin.H{"message": "Share revoked"})
}

// SearchUsers returns usernames matching prefix (for share autocomplete)
func SearchUsers(c *gin.Context) {
	prefix := c.Query("q")
	excludeID := c.Query("exclude") // current user to exclude
	if len(prefix) < 2 {
		c.JSON(http.StatusOK, gin.H{"usernames": []string{}})
		return
	}

	var usernames []string
	query := database.DB.Model(&models.User{}).Where("username LIKE ?", prefix+"%").Limit(10)
	if excludeID != "" {
		query = query.Where("username != ?", excludeID)
	}
	if err := query.Pluck("username", &usernames).Error; err != nil {
		c.JSON(http.StatusOK, gin.H{"usernames": []string{}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"usernames": usernames})
}

// GetUserPublicKey returns a user's public key (for share encryption)
func GetUserPublicKey(c *gin.Context) {
	username := c.Param("username")
	if username == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "username required"})
		return
	}

	var user models.User
	if err := database.DB.Where("username = ?", username).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "User not found"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"public_key": user.PublicKey})
}
