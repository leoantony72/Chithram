package controllers

import (
	"fmt"
	"net/http"
	"path/filepath"

	"chithram/services"

	"github.com/gin-gonic/gin"
)

// BatchUploadImages handles multiple image uploads to MinIO
func BatchUploadImages(c *gin.Context) {
	// Multipart form
	form, err := c.MultipartForm()
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Failed to parse multipart form"})
		return
	}

	// Get Username
	username := c.PostForm("username")
	if username == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Username is required"})
		return
	}

	files := form.File["files"]
	if len(files) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "No files uploaded (key 'files' missing or empty)"})
		return
	}

	var uploaded []map[string]interface{}
	var failed []map[string]interface{}

	for _, file := range files {
		// 1. Get file stream
		src, err := file.Open()
		if err != nil {
			failed = append(failed, gin.H{"filename": file.Filename, "error": "Could not open file"})
			continue
		}

		// 2. Determine path: username/filename
		filename := filepath.Base(file.Filename)
		objectName := fmt.Sprintf("%s/%s", username, filename)

		// 3. Upload to MinIO
		info, err := services.UploadToMinio(objectName, src, file.Size, file.Header.Get("Content-Type"))
		src.Close() // Close immediately after upload

		if err != nil {
			failed = append(failed, gin.H{"filename": file.Filename, "error": fmt.Sprintf("MinIO upload failed: %v", err)})
		} else {
			uploaded = append(uploaded, gin.H{
				"filename": file.Filename,
				"location": info.Location,
				"key":      info.Key,
				"etag":     info.ETag,
				"size":     info.Size,
			})
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"message":        fmt.Sprintf("Processed %d files", len(files)),
		"uploaded_count": len(uploaded),
		"failed_count":   len(failed),
		"uploaded":       uploaded,
		"failed":         failed,
	})
}
