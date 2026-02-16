package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"

	"github.com/gin-gonic/gin"
)

// ModelInfo represents the metadata of a model
type ModelInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"` // For now, we can use file mod time or a hash as version
	Size    int64  `json:"size"`
}

func main() {
	r := gin.Default()

	// Ensure models directory exists
	modelsDir := "./models"
	if _, err := os.Stat(modelsDir); os.IsNotExist(err) {
		os.Mkdir(modelsDir, 0755)
	}

	// Model Info Endpoint
	r.GET("/models/:name/info", func(c *gin.Context) {
		modelName := c.Param("name")
		modelPath := filepath.Join(modelsDir, modelName+".onnx")

		info, err := os.Stat(modelPath)
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "Model not found"})
			return
		}

		c.JSON(http.StatusOK, ModelInfo{
			Name:    modelName,
			Version: info.ModTime().String(), // Simple versioning for now
			Size:    info.Size(),
		})
	})

	// Model Download Endpoint
	r.GET("/models/:name/download", func(c *gin.Context) {
		modelName := c.Param("name")
		modelPath := filepath.Join(modelsDir, modelName+".onnx")

		if _, err := os.Stat(modelPath); os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "Model not found"})
			return
		}

		c.File(modelPath)
	})

	// List all available models (Optional but helpful)
	r.GET("/models", func(c *gin.Context) {
		files, err := os.ReadDir(modelsDir)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "Unable to read models directory"})
			return
		}

		var models []string
		for _, file := range files {
			if !file.IsDir() && filepath.Ext(file.Name()) == ".onnx" {
				models = append(models, file.Name()) // or strip extension
			}
		}
		c.JSON(http.StatusOK, gin.H{"models": models})
	})

	port := "8080"
	fmt.Printf("Server starting on port %s\n", port)
	r.Run(":" + port)
}
