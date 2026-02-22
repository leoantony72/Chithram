package services

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"chithram/database"
	"chithram/models"
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

	// PROACTIVE: Evaluate key models on startup and print to console
	go func() {
		pythonExe := "python"
		if _, err := os.Stat("../.venv/Scripts/python.exe"); err == nil {
			pythonExe, _ = filepath.Abs("../.venv/Scripts/python.exe")
		}

		evalModel := func(modelPath string, label string) {
			if _, err := os.Stat(modelPath); err != nil {
				log.Printf("SKIP: Model %s not found", modelPath)
				return
			}
			log.Printf("--- EVALUATING %s (%s) ---", label, modelPath)
			evalCmd := exec.Command(pythonExe, "./scripts/evaluate_model.py", "--model", modelPath)
			evalOutput, err := evalCmd.CombinedOutput()
			if err != nil {
				log.Printf("ERROR: Evaluation failed: %v\nOutput: %s", err, string(evalOutput))
				return
			}

			fmt.Printf("\n>>> EVALUATION RESULT [%s] <<<\n%s\n", label, string(evalOutput))

			type EvalResult struct {
				Accuracy float64 `json:"accuracy"`
				Loss     float64 `json:"loss"`
			}
			var res EvalResult
			rawStr := string(evalOutput)
			startIndex := strings.Index(rawStr, "{")
			if startIndex != -1 {
				jsonPart := rawStr[startIndex:]
				if err := json.Unmarshal([]byte(jsonPart), &res); err == nil {
					metric := models.ModelMetric{
						ModelName: "face-detection",
						Version:   label,
						Accuracy:  res.Accuracy,
						Loss:      res.Loss,
						CreatedAt: time.Now(),
					}
					database.DB.Create(&metric)
				}
			}
		}

		// 1. Evaluate the Original Baseline
		evalModel("./models/yolov8n.onnx", "original_baseline")

		// 2. Evaluate the Current Live Model
		evalModel("./models/face-detection.onnx", "current_live")

		// 3. Backfill history if empty (keeping original logic for other models)
		var count int64
		database.DB.Model(&models.ModelMetric{}).Count(&count)
		if count <= 2 { // Only original and current exist
			log.Println("Dashboard history is empty. Attempting to backfill from fl_models...")
			files, _ := ioutil.ReadDir(AggregatedModelsDir)
			for _, f := range files {
				if !f.IsDir() && filepath.Ext(f.Name()) == ".onnx" {
					evalModel(filepath.Join(AggregatedModelsDir, f.Name()), f.Name())
				}
			}
		}
		log.Println("Startup Evaluation and Backfill complete.")
	}()
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
	// Use the project's virtual environment if available, otherwise fallback to system python
	pythonExe := "python"
	if _, err := os.Stat("../.venv/Scripts/python.exe"); err == nil {
		pythonExe, _ = filepath.Abs("../.venv/Scripts/python.exe")
	} else if _, err := os.Stat("../.venv/bin/python"); err == nil {
		pythonExe, _ = filepath.Abs("../.venv/bin/python")
	}

	cmd := exec.Command(pythonExe, "./scripts/aggregate_models.py", "--output", outputPath)
	cmd.Args = append(cmd.Args, modelFiles...)

	// Capture output for debugging
	output, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("Error running aggregation script: %v\nOutput: %s", err, string(output))
		return
	}

	log.Printf("Aggregation successful! New global model: %s", newGlobalModelName)
	CurrentGlobalModelPath = outputPath

	// --- EVALUATION PASS ---
	// Evaluate Old vs New Model Accuracy
	oldModelPath := "./models/face-detection.onnx"

	evalModel := func(modelPath string, versionName string) {
		log.Printf("Evaluating model: %s", modelPath)
		evalCmd := exec.Command(pythonExe, "./scripts/evaluate_model.py", "--model", modelPath)
		evalOutput, evalErr := evalCmd.CombinedOutput()
		if evalErr == nil {
			type EvalResult struct {
				Accuracy float64 `json:"accuracy"`
				Loss     float64 `json:"loss"`
			}
			var res EvalResult
			rawStr := string(evalOutput)
			startIndex := strings.Index(rawStr, "{")
			if startIndex != -1 {
				jsonPart := rawStr[startIndex:]
				if err := json.Unmarshal([]byte(jsonPart), &res); err == nil {
					metric := models.ModelMetric{
						ModelName: "face-detection",
						Version:   versionName,
						Accuracy:  res.Accuracy,
						Loss:      res.Loss,
						CreatedAt: time.Now(),
					}
					database.DB.Create(&metric)
					log.Printf("Stored metrics for %s: Acc=%.4f, Loss=%.4f", versionName, res.Accuracy, res.Loss)
				} else {
					log.Printf("Failed to unmarshal JSON from eval output: %v\nRaw: %s", err, rawStr)
				}
			} else {
				log.Printf("No JSON found in eval output: %s", rawStr)
			}
		} else {
			log.Printf("Failed to evaluate model %s: %v\nOutput: %s", modelPath, evalErr, string(evalOutput))
		}
	}

	// Evaluate Old (if exists)
	if _, err := os.Stat(oldModelPath); err == nil {
		evalModel(oldModelPath, "previous")
	}
	// Evaluate New
	evalModel(outputPath, newGlobalModelName)

	// Step: Rotate face-detection.onnx in backend/models
	if _, err := os.Stat(oldModelPath); err == nil {
		oldModelName := fmt.Sprintf("face-detection_old_%d.onnx", time.Now().Unix())
		archivePath := filepath.Join("./models", oldModelName)
		if err := os.Rename(oldModelPath, archivePath); err != nil {
			log.Printf("Failed to rename old face-detection.onnx: %v", err)
		} else {
			log.Printf("Renamed old model to %s", oldModelName)
		}
	}

	// Step: Move/Copy the new aggregated model to backend/models/face-detection.onnx
	inputData, err := ioutil.ReadFile(outputPath)
	if err == nil {
		if err := ioutil.WriteFile(oldModelPath, inputData, 0644); err != nil {
			log.Printf("Failed to write new face-detection.onnx: %v", err)
		} else {
			log.Printf("Successfully replaced backend/models/face-detection.onnx")

			// Update Database Metadata
			var meta models.ModelMetadata
			dbName := "face-detection"
			if err := database.DB.Where("name = ?", dbName).First(&meta).Error; err == nil {
				meta.Version = time.Now().Format("20060102150405")
				meta.Size = int64(len(inputData))
				meta.UpdatedAt = time.Now()
				database.DB.Save(&meta)
				log.Printf("Updated database metadata for %s to version %s", dbName, meta.Version)
			}
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
