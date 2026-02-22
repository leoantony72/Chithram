package models

import (
	"time"
)

type ModelMetric struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	ModelName string    `json:"model_name"`
	Version   string    `json:"version"`
	Accuracy  float64   `json:"accuracy"`
	Loss      float64   `json:"loss"`
	CreatedAt time.Time `json:"created_at"`
}
