package controllers

import (
	"fmt"
	"io"
	"net/http"
	"time"

	"chithram/database"
	"chithram/models"
	"chithram/services"

	"github.com/gin-gonic/gin"
)

// ImageResponse mirrors the database model but adds Signed URLs
type ImageResponse struct {
	models.Image
	OriginalURL string `json:"original_url"`
	Thumb256URL string `json:"thumb_256_url"`
	Thumb64URL  string `json:"thumb_64_url"`
}

type AlbumResponse struct {
	Name       string `json:"name"`
	CoverImage string `json:"cover_image_url"`
}

// RegisterImage registers an image's metadata after it has been uploaded to MinIO
func RegisterImage(c *gin.Context) {
	fmt.Println("RegisterImage: Received request")
	var input models.Image
	if err := c.ShouldBindJSON(&input); err != nil {
		fmt.Println("RegisterImage Bind Error:", err)
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Set timestamps if not provided
	if input.CreatedAt.IsZero() {
		input.CreatedAt = time.Now()
	}
	if input.UploadedAt.IsZero() {
		input.UploadedAt = time.Now()
	}
	if input.ModifiedAt.IsZero() {
		input.ModifiedAt = time.Now()
	}

	// Save to DB
	if err := database.DB.Create(&input).Error; err != nil {
		fmt.Println("RegisterImage DB Error:", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to register image"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Image registered successfully", "image": input})
}

// ListImages returns a paginated list of images with signed URLs
// Query Params: limit (default 50), cursor (last modified_at timestamp, optional)
func ListImages(c *gin.Context) {
	userID := c.Query("user_id") // Should come from auth token in real app
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	limit := 50

	page := 0
	cursor := c.Query("cursor")
	if cursor != "" {
		// Interpret cursor as page number for robust pagination instead of buggy time strings
		fmt.Sscanf(cursor, "%d", &page)
	}

	var images []models.Image
	query := database.DB.Where("user_id = ? AND is_deleted = ?", userID, false)

	albumFilter := c.Query("album")
	if albumFilter != "" {
		query = query.Where("album = ?", albumFilter)
	}

	query = query.Where("is_deleted = ?", false)

	query = query.Order("modified_at DESC, image_id DESC").
		Limit(limit).
		Offset(page * limit)

	if err := query.Find(&images).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Database error"})
		return
	}

	// Generate Signed URLs
	response := []ImageResponse{} // Initialize slice to ensure [] is returned instead of null
	for _, img := range images {
		resp := ImageResponse{Image: img}
		expiry := 7 * 24 * time.Hour

		// Adjusted to Originals and Thumbnails folders
		originalPath := fmt.Sprintf("%s/images/originals/%s.enc", img.UserID, img.ImageID)
		thumb256Path := fmt.Sprintf("%s/images/thumbnails/%s_thumb_256.enc", img.UserID, img.ImageID)
		thumb64Path := fmt.Sprintf("%s/images/thumbnails/%s_thumb_64.enc", img.UserID, img.ImageID)

		resp.OriginalURL, _ = services.GetPresignedURL(originalPath, expiry)
		resp.Thumb256URL, _ = services.GetPresignedURL(thumb256Path, expiry)
		resp.Thumb64URL, _ = services.GetPresignedURL(thumb64Path, expiry)

		response = append(response, resp)
	}

	nextCursor := ""
	if len(images) == limit {
		nextCursor = fmt.Sprintf("%d", page+1)
	}

	c.JSON(http.StatusOK, gin.H{
		"images":      response,
		"next_cursor": nextCursor,
	})
}

// SyncImages returns incremental updates since a given timestamp
func SyncImages(c *gin.Context) {
	userID := c.Query("user_id")
	modifiedAfter := c.Query("modified_after")

	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var images []models.Image
	query := database.DB.Where("user_id = ?", userID)

	if modifiedAfter != "" {
		query = query.Where("modified_at > ?", modifiedAfter)
	}

	// Return everything since modified_after (including deleted)
	if err := query.Order("modified_at ASC").Limit(100).Find(&images).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Database error"})
		return
	}

	var response []ImageResponse
	for _, img := range images {
		resp := ImageResponse{Image: img}
		// Only generate URLs if not deleted
		if !img.IsDeleted {
			expiry := 7 * 24 * time.Hour
			originalPath := fmt.Sprintf("%s/images/originals/%s.enc", img.UserID, img.ImageID)
			thumb256Path := fmt.Sprintf("%s/images/thumbnails/%s_thumb_256.enc", img.UserID, img.ImageID)
			thumb64Path := fmt.Sprintf("%s/images/thumbnails/%s_thumb_64.enc", img.UserID, img.ImageID)

			resp.OriginalURL, _ = services.GetPresignedURL(originalPath, expiry)
			resp.Thumb256URL, _ = services.GetPresignedURL(thumb256Path, expiry)
			resp.Thumb64URL, _ = services.GetPresignedURL(thumb64Path, expiry)
		}
		response = append(response, resp)
	}

	nextCursor := ""
	if len(images) > 0 {
		nextCursor = images[len(images)-1].ModifiedAt.Format(time.RFC3339Nano)
	}

	c.JSON(http.StatusOK, gin.H{
		"updates":     response,
		"next_cursor": nextCursor,
	})
}

// GenerateUploadURLs provides presigned URLs for client-side upload
func GenerateUploadURLs(c *gin.Context) {
	var input struct {
		ImageID  string   `json:"image_id" binding:"required"`
		UserID   string   `json:"user_id" binding:"required"`  // Should be from auth context
		Variants []string `json:"variants" binding:"required"` // e.g. ["original", "thumb_256"]
	}

	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	urls := make(map[string]string)
	expiry := 7 * 24 * time.Hour

	for _, variant := range input.Variants {
		var objectName string
		if variant == "original" {
			objectName = fmt.Sprintf("%s/images/originals/%s.enc", input.UserID, input.ImageID)
		} else if variant == "faces" {
			objectName = fmt.Sprintf("%s/metadata/faces.enc", input.UserID)
		} else {
			objectName = fmt.Sprintf("%s/images/thumbnails/%s_%s.enc", input.UserID, input.ImageID, variant)
		}

		url, err := services.GetPresignedPutURL(objectName, expiry)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to generate URL for %s: %v", variant, err)})
			return
		}
		urls[variant] = url
	}

	c.JSON(http.StatusOK, gin.H{"urls": urls})
}

// GetChecksums returns a list of all checksums for a user to allow client-side deduplication
func GetChecksums(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var checksums []string
	// Select only checksum column where user_id matches and is not deleted
	if err := database.DB.Model(&models.Image{}).
		Where("user_id = ? AND is_deleted = ?", userID, false).
		Pluck("checksum", &checksums).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Database error"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"checksums": checksums})
}

// GetSourceIDs returns a list of all source_ids for a user to allow fast client-side deduplication
func GetSourceIDs(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var sourceIDs []string
	if err := database.DB.Model(&models.Image{}).
		Where("user_id = ? AND is_deleted = ?", userID, false).
		Pluck("source_id", &sourceIDs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Database error"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"source_ids": sourceIDs})
}

// GetFacesDownloadURL generates a presigned GET URL to download the user's master encrypted faces blob and includes the current version
func GetFacesDownloadURL(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var user models.User
	if err := database.DB.Where("username = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "User not found"})
		return
	}

	objectName := fmt.Sprintf("%s/metadata/faces.enc", userID)
	url, err := services.GetPresignedURL(objectName, 7*24*time.Hour)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to generate download URL"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"url":     url,
		"version": user.PeopleVersion,
	})
}

// RegisterPeopleVersion updates the people_version for a user and returns the new version
func RegisterPeopleVersion(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var user models.User
	if err := database.DB.Where("username = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "User not found"})
		return
	}

	// Increment version
	user.PeopleVersion++
	if err := database.DB.Save(&user).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to update version"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "People version updated",
		"version": user.PeopleVersion,
	})
}

// GetPeopleVersion returns the current people_version for a user
func GetPeopleVersion(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var user models.User
	if err := database.DB.Where("username = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "User not found"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"version": user.PeopleVersion,
	})
}

// GetSingleImage returns a single image metadata with signed URLs
func GetSingleImage(c *gin.Context) {
	imageID := c.Param("id")
	userID := c.Query("user_id")

	if userID == "" || imageID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id and image_id required"})
		return
	}

	var img models.Image
	if err := database.DB.Where("user_id = ? AND image_id = ? AND is_deleted = ?", userID, imageID, false).First(&img).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "Image not found"})
		return
	}

	resp := ImageResponse{Image: img}
	expiry := 7 * 24 * time.Hour

	originalPath := fmt.Sprintf("%s/images/originals/%s.enc", img.UserID, img.ImageID)
	thumb256Path := fmt.Sprintf("%s/images/thumbnails/%s_thumb_256.enc", img.UserID, img.ImageID)
	thumb64Path := fmt.Sprintf("%s/images/thumbnails/%s_thumb_64.enc", img.UserID, img.ImageID)

	resp.OriginalURL, _ = services.GetPresignedURL(originalPath, expiry)
	resp.Thumb256URL, _ = services.GetPresignedURL(thumb256Path, expiry)
	resp.Thumb64URL, _ = services.GetPresignedURL(thumb64Path, expiry)

	c.JSON(http.StatusOK, gin.H{"image": resp})
}

// GetAlbums returns a list of distinct albums created by the user
func GetAlbums(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var results []struct {
		Album   string
		ImageID string
	}

	// Fetch distinct albums and their most recent image_id
	query := `
		SELECT album, image_id
		FROM images i1
		WHERE user_id = ? AND is_deleted = 0 AND album != ''
		AND created_at = (
			SELECT MAX(created_at)
			FROM images i2
			WHERE i2.album = i1.album AND i2.user_id = i1.user_id AND i2.is_deleted = 0
		)
		GROUP BY album
	`
	if err := database.DB.Raw(query, userID).Scan(&results).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch albums"})
		return
	}

	var albumsResp []AlbumResponse
	expiry := 7 * 24 * time.Hour

	for _, res := range results {
		thumb256Path := fmt.Sprintf("%s/images/thumbnails/%s_thumb_256.enc", userID, res.ImageID)
		thumb256URL, _ := services.GetPresignedURL(thumb256Path, expiry)

		albumsResp = append(albumsResp, AlbumResponse{
			Name:       res.Album,
			CoverImage: thumb256URL,
		})
	}

	if albumsResp == nil {
		albumsResp = []AlbumResponse{}
	}

	c.JSON(http.StatusOK, gin.H{"albums": albumsResp})
}

// DeleteImages handles permanent removal of images from cloud storage while soft-deleting in the DB for sync.
func DeleteImages(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var input struct {
		ImageIDs []string `json:"image_ids" binding:"required"`
	}

	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if len(input.ImageIDs) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "No image IDs provided"})
		return
	}

	// Soft delete in DB (set is_deleted = 1 and update modified_at for sync)
	now := time.Now()
	if err := database.DB.Model(&models.Image{}).
		Where("user_id = ? AND image_id IN (?)", userID, input.ImageIDs).
		Updates(map[string]interface{}{
			"is_deleted":  true,
			"modified_at": now,
		}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to mark images as deleted in database"})
		return
	}

	// Issue hard deletion commands to MinIO to free up space and ensure privacy
	for _, id := range input.ImageIDs {
		originalPath := fmt.Sprintf("%s/images/originals/%s.enc", userID, id)
		thumb256Path := fmt.Sprintf("%s/images/thumbnails/%s_thumb_256.enc", userID, id)
		thumb64Path := fmt.Sprintf("%s/images/thumbnails/%s_thumb_64.enc", userID, id)

		services.DeleteObject(originalPath)
		services.DeleteObject(thumb256Path)
		services.DeleteObject(thumb64Path)
	}

	c.JSON(http.StatusOK, gin.H{"message": fmt.Sprintf("Successfully processing deletion for %d images", len(input.ImageIDs))})
}

// UpdateImageLocation performs a bulk update of latitude and longitude for the specified image IDs.
func UpdateImageLocation(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var input struct {
		ImageIDs  []string `json:"image_ids" binding:"required"`
		Latitude  float64  `json:"latitude"`
		Longitude float64  `json:"longitude"`
	}

	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if len(input.ImageIDs) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "No image IDs provided"})
		return
	}

	now := time.Now()
	if err := database.DB.Model(&models.Image{}).
		Where("user_id = ? AND image_id IN (?)", userID, input.ImageIDs).
		Updates(map[string]interface{}{
			"latitude":    input.Latitude,
			"longitude":   input.Longitude,
			"modified_at": now,
		}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to update locations in database"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": fmt.Sprintf("Successfully updated location for %d images", len(input.ImageIDs))})
}

// UpdateImageAlbum performs a bulk update of the album property for the specified image IDs.
func UpdateImageAlbum(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	var input struct {
		ImageIDs  []string `json:"image_ids" binding:"required"`
		AlbumName string   `json:"album_name" binding:"required"`
	}

	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if len(input.ImageIDs) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "No image IDs provided"})
		return
	}

	now := time.Now()
	if err := database.DB.Model(&models.Image{}).
		Where("user_id = ? AND image_id IN (?)", userID, input.ImageIDs).
		Updates(map[string]interface{}{
			"album":       input.AlbumName,
			"modified_at": now,
		}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to update albums in database"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": fmt.Sprintf("Successfully assigned %d images to album %s", len(input.ImageIDs), input.AlbumName)})
}

// DownloadImage proxies a file download from MinIO to the client
func DownloadImage(c *gin.Context) {
	imageID := c.Param("id")
	userID := c.Query("user_id")
	variant := c.Query("variant")

	if userID == "" || imageID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id and id are required"})
		return
	}

	var objectName string
	if variant == "original" {
		objectName = fmt.Sprintf("%s/images/originals/%s.enc", userID, imageID)
	} else if variant == "thumb_64" {
		objectName = fmt.Sprintf("%s/images/thumbnails/%s_thumb_64.enc", userID, imageID)
	} else {
		// Default to 256
		objectName = fmt.Sprintf("%s/images/thumbnails/%s_thumb_256.enc", userID, imageID)
	}

	object, err := services.DownloadFromMinio(objectName)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "File not found in storage"})
		return
	}
	defer object.Close()

	// Set content type for binary data
	c.Header("Content-Type", "application/octet-stream")
	c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%s.enc", imageID))

	if _, err := io.Copy(c.Writer, object); err != nil {
		fmt.Printf("Error streaming from MinIO: %v\n", err)
	}
}
