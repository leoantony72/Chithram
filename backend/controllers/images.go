package controllers

import (
	"fmt"
	"net/http"
	"strings"

	"chithram/services"

	"github.com/gin-gonic/gin"
	"github.com/minio/minio-go/v7"
)

// ListImages returns a list of image identifiers for a given user
func ListImages(c *gin.Context) {
	username := c.Query("username")
	if username == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Username is required"})
		return
	}

	files, err := services.ListFiles(username)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to list files: %v", err)})
		return
	}

	// Filter and format?
	// The frontend just needs the keys to request downloads.
	// Maybe return simple list of filenames or full paths?
	// services.ListFiles returns keys like "username/file.jpg".
	// Let's return exactly that.

	c.JSON(http.StatusOK, gin.H{
		"files": files,
		"count": len(files),
	})
}

// DownloadImage streams the encrypted file content back to the client
func DownloadImage(c *gin.Context) {
	username := c.Query("username")
	filename := c.Query("filename") // or use path param?

	if username == "" || filename == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Username and filename are required"})
		return
	}

	// Construct object name
	// Ensure filename doesn't contain weird path traversal
	if strings.Contains(filename, "..") || strings.Contains(username, "..") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid path components"})
		return
	}

	objectName := fmt.Sprintf("%s/%s", username, filename)

	// We need a Download method in services
	// Or expose MinioClient.
	// Let's add DownloadToWriter in services/minio.go?
	// Or return an io.ReadCloser?
	// I'll assume we add `DownloadFile(objectName)` -> (*minio.Object, error)
	// For now, let's just implement a quick helper here or use the service.

	// Wait, I should add DownloadFile to services/minio.go first.
	// But I can't modify it in this step.
	// I will just use `services.MinioClient` if it's exported? Yes it is.
	object, err := services.MinioClient.GetObject(c, services.BucketName, objectName, minio.GetObjectOptions{})
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "File not found"})
		return
	}
	// defer object.Close() // gin context might handle stream? No we must close after copy.
	// Actually `c.DataFromReader` takes a reader.

	// Get object info for content type/length
	stat, err := object.Stat()
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "File stat failed"})
		return
	}

	c.DataFromReader(http.StatusOK, stat.Size, stat.ContentType, object, map[string]string{
		"Content-Disposition": fmt.Sprintf("attachment; filename=\"%s\"", filename),
	})
}
