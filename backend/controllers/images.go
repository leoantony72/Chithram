package controllers

import (
	"fmt"
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
		expiry := 15 * time.Minute

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
			expiry := 15 * time.Minute
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
	expiry := 15 * time.Minute

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

// GetFacesDownloadURL generates a presigned GET URL to download the user's master encrypted faces blob
func GetFacesDownloadURL(c *gin.Context) {
	userID := c.Query("user_id")
	if userID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user_id is required"})
		return
	}

	objectName := fmt.Sprintf("%s/metadata/faces.enc", userID)
	url, err := services.GetPresignedURL(objectName, 15*time.Minute)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to generate download URL"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"url": url})
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
	expiry := 15 * time.Minute

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
	expiry := 15 * time.Minute

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
