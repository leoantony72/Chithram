package services

import (
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

var (
	// PendingUpdatesDir is where we store client models waiting to be aggregated
	PendingUpdatesDir = "./fl_updates/pending"
	// AggregatedModelsDir is where we store the aggregated models
	AggregatedModelsDir = "./fl_models"
	// CurrentGlobalModelPath points to the latest aggregated model
	CurrentGlobalModelPath string
	// AggregationInterval is how often we check for updates
	AggregationInterval = 1 * time.Minute
	// Min updates required before aggregation
	MinUpdatesRequired = 2

	mu sync.Mutex
)

// InitFLService ensures directories exist and starts the background worker
func InitFLService() {
	// Create directories
	if _, err := os.Stat(PendingUpdatesDir); os.IsNotExist(err) {
		os.MkdirAll(PendingUpdatesDir, 0755)
	}
	if _, err := os.Stat(AggregatedModelsDir); os.IsNotExist(err) {
		os.MkdirAll(AggregatedModelsDir, 0755)
	}

	// Start background worker
	go func() {
		ticker := time.NewTicker(AggregationInterval)
		for range ticker.C {
			AggregateModels()
		}
	}()

	// Initial check for latest global model
	files, _ := ioutil.ReadDir(AggregatedModelsDir)
	var latestFile string
	var latestTime time.Time

	for _, f := range files {
		if !f.IsDir() && filepath.Ext(f.Name()) == ".onnx" {
			if f.ModTime().After(latestTime) {
				latestTime = f.ModTime()
				latestFile = f.Name()
			}
		}
	}
	if latestFile != "" {
		CurrentGlobalModelPath = filepath.Join(AggregatedModelsDir, latestFile)
		log.Printf("Found existing global model: %s", latestFile)
	} else {
		// Default to the main model if no fl_models exist yet
		CurrentGlobalModelPath = "./models/face-detection.onnx"
	}
}

// AggregateModels checks the pending updates folder and runs the aggregation script if enough updates are present
func AggregateModels() {
	mu.Lock()
	defer mu.Unlock()

	files, err := ioutil.ReadDir(PendingUpdatesDir)
	if err != nil {
		log.Printf("Error reading pending updates dir: %v", err)
		return
	}

	// Count only valid model files
	var modelFiles []string
	for _, f := range files {
		if !f.IsDir() && filepath.Ext(f.Name()) == ".onnx" {
			modelFiles = append(modelFiles, filepath.Join(PendingUpdatesDir, f.Name()))
		}
	}

	if len(modelFiles) < MinUpdatesRequired {
		log.Printf("Not enough updates to aggregate. Pending: %d, Required: %d", len(modelFiles), MinUpdatesRequired)
		return
	}

	log.Printf("Aggregating %d models...", len(modelFiles))

	// Define output path for the new global model
	newGlobalModelName := fmt.Sprintf("global_model_%d.onnx", time.Now().Unix())
	outputPath := filepath.Join(AggregatedModelsDir, newGlobalModelName)

	// Call Python script to perform weighted averaging (FedAvg)
	// We'll pass the list of models as arguments along with the output path
	// Adjust python path if needed (e.g., "python3" on linux, "python" on windows)
	cmd := exec.Command("python", "./scripts/aggregate_models.py", "--output", outputPath)
	cmd.Args = append(cmd.Args, modelFiles...)

	// Capture output for debugging
	output, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("Error running aggregation script: %v\nOutput: %s", err, string(output))
		return
	}

	log.Printf("Aggregation successful! New global model: %s", newGlobalModelName)
	CurrentGlobalModelPath = outputPath

	// Step: Rotate face-detection.onnx in backend/models
	targetModelPath := "./models/face-detection.onnx"
	if _, err := os.Stat(targetModelPath); err == nil {
		oldModelName := fmt.Sprintf("face-detection_old_%d.onnx", time.Now().Unix())
		oldModelPath := filepath.Join("./models", oldModelName)
		if err := os.Rename(targetModelPath, oldModelPath); err != nil {
			log.Printf("Failed to rename old face-detection.onnx: %v", err)
		} else {
			log.Printf("Renamed old model to %s", oldModelName)
		}
	}

	// Step: Move/Copy the new aggregated model to backend/models/face-detection.onnx
	inputData, err := ioutil.ReadFile(outputPath)
	if err == nil {
		if err := ioutil.WriteFile(targetModelPath, inputData, 0644); err != nil {
			log.Printf("Failed to write new face-detection.onnx: %v", err)
		} else {
			log.Printf("Successfully replaced backend/models/face-detection.onnx")
			// Optional: you can choose to delete outputPath now if you strictly only want it in models/
		}
	} else {
		log.Printf("Failed to read the newly aggregated model for copying: %v", err)
	}

	// Cleanup pending updates
	for _, f := range modelFiles {
		if err := os.Remove(f); err != nil {
			log.Printf("Warning: Failed to delete processed update %s: %v", f, err)
		}
	}
}
