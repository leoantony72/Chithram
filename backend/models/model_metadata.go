package models

import "time"

type ModelMetadata struct {
	Name      string    `gorm:"primaryKey" json:"name"`
	Version   string    `json:"version"`
	Size      int64     `json:"size"`
	UpdatedAt time.Time `json:"updated_at"`
}
