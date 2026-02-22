package controllers

import (
	"fmt"
	"net/http"
	"path/filepath"
	"time"

	"chithram/services"

	"github.com/gin-gonic/gin"
)

// UploadLocalUpdate handles the reception of locally trained model updates
func UploadLocalUpdate(c *gin.Context) {
	// 1. Receive the file
	file, err := c.FormFile("model")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "No model file provided"})
		return
	}

	// 2. Validate (optional, check size/extension)
	ext := filepath.Ext(file.Filename)
	if ext != ".onnx" && ext != ".pt" && ext != ".tflite" {
		// allowing multiple formats for now, though ONNX is preferred based on context
	}

	// 3. Save to a temporary "pending" directory managed by the FL service
	// We use a timestamp-based name to avoid collisions
	filename := fmt.Sprintf("update_%d_%s", time.Now().UnixNano(), file.Filename)
	savePath := filepath.Join(services.PendingUpdatesDir, filename)

	if err := c.SaveUploadedFile(file, savePath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to save model update"})
		return
	}

	// 4. Trigger check (optional, or just let the background worker handle it)
	// services.CheckForAggregation()

	c.JSON(http.StatusOK, gin.H{"message": "Model update received successfully", "id": filename})
}

// GetGlobalModel serves the current global model to clients
func GetGlobalModel(c *gin.Context) {
	modelPath := services.CurrentGlobalModelPath
	if modelPath == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "No global model available yet"})
		return
	}
	c.File(modelPath)
}
