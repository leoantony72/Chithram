package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"chithram/controllers"
	"chithram/database"
	"chithram/models"
	"chithram/services"

	"github.com/gin-gonic/gin"
)

// ModelInfo represents the metadata of a model
type ModelInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"` // For now, we can use file mod time or a hash as version
	Size    int64  `json:"size"`
}

func main() {
	// Connect to database
	database.Connect()
	// Auto migrate
	database.DB.AutoMigrate(&models.User{}, &models.Image{}, &models.ModelMetadata{}, &models.ModelMetric{})

	// Seed initial model metadata if missing
	seedModelMetadata()

	// Init MinIO
	services.InitMinio()

	r := gin.Default()

	// CORS Middleware
	r.Use(func(c *gin.Context) {
		origin := c.Request.Header.Get("Origin")
		if origin != "" {
			c.Writer.Header().Set("Access-Control-Allow-Origin", origin)
		} else {
			c.Writer.Header().Set("Access-Control-Allow-Origin", "*")
		}
		c.Writer.Header().Set("Access-Control-Allow-Credentials", "true")
		c.Writer.Header().Set("Access-Control-Allow-Headers", "Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization, accept, origin, Cache-Control, X-Requested-With")
		c.Writer.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS, GET, PUT, DELETE")

		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}

		c.Next()
	})

	// Auth Endpoints
	r.POST("/signup", controllers.Signup)
	r.POST("/login", controllers.Login)

	// Upload Endpoint
	r.POST("/upload", controllers.BatchUploadImages)

	// Image Endpoints
	r.DELETE("/images", controllers.DeleteImages)
	r.PUT("/images/location", controllers.UpdateImageLocation)
	r.PUT("/images/album", controllers.UpdateImageAlbum)
	r.GET("/albums", controllers.GetAlbums)
	r.GET("/images", controllers.ListImages)
	r.GET("/images/:id", controllers.GetSingleImage)
	r.POST("/images/register", controllers.RegisterImage)
	r.POST("/images/upload_urls", controllers.GenerateUploadURLs)
	r.GET("/images/checksums", controllers.GetChecksums)  // Add this
	r.GET("/images/source_ids", controllers.GetSourceIDs) // Add this for fast deduplication
	r.GET("/images/faces", controllers.GetFacesDownloadURL)
	r.GET("/images/faces/version", controllers.GetPeopleVersion)
	r.POST("/images/faces/register", controllers.RegisterPeopleVersion)
	r.GET("/sync", controllers.SyncImages)
	r.GET("/images/download/:id", controllers.DownloadImage)

	// Federated Learning Endpoints
	services.InitFLService()
	r.POST("/fl/update", controllers.UploadLocalUpdate)
	r.GET("/fl/global", controllers.GetGlobalModel)
	r.GET("/dashboard", controllers.GetDashboard)

	// Ensure models directory exists
	modelsDir := "./models"
	if _, err := os.Stat(modelsDir); os.IsNotExist(err) {
		os.Mkdir(modelsDir, 0755)
	}

	// Model Info Endpoint
	r.GET("/models/:name/info", func(c *gin.Context) {
		modelName := c.Param("name")

		var meta models.ModelMetadata
		if err := database.DB.Where("name = ?", modelName).First(&meta).Error; err != nil {
			// Fallback to file system if database entry is missing
			modelPath := filepath.Join(modelsDir, modelName+".onnx")
			info, err := os.Stat(modelPath)
			if os.IsNotExist(err) {
				c.JSON(http.StatusNotFound, gin.H{"error": "Model not found"})
				return
			}

			c.JSON(http.StatusOK, ModelInfo{
				Name:    modelName,
				Version: info.ModTime().Format("20060102150405"),
				Size:    info.Size(),
			})
			return
		}

		c.JSON(http.StatusOK, ModelInfo{
			Name:    meta.Name,
			Version: meta.Version,
			Size:    meta.Size,
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
	if err := r.Run(":" + port); err != nil {
		fmt.Printf("Error starting server: %v\n", err)
	}
}

func seedModelMetadata() {
	modelsDir := "./models"
	files, _ := os.ReadDir(modelsDir)
	for _, f := range files {
		if !f.IsDir() && filepath.Ext(f.Name()) == ".onnx" {
			name := f.Name()[:len(f.Name())-5]
			info, _ := f.Info()

			var meta models.ModelMetadata
			if database.DB.Where("name = ?", name).First(&meta).Error != nil {
				// Seed new
				meta = models.ModelMetadata{
					Name:      name,
					Version:   info.ModTime().Format("20060102150405"),
					Size:      info.Size(),
					UpdatedAt: time.Now(),
				}
				database.DB.Create(&meta)
			}
		}
	}
}
