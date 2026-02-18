package models

import (
	"time"
)

type Image struct {
	ImageID    string    `gorm:"primaryKey;type:text" json:"image_id"` // SQLite uses text for UUID
	UserID     string    `gorm:"index" json:"user_id"`
	CreatedAt  time.Time `json:"created_at"`
	UploadedAt time.Time `json:"uploaded_at"`
	ModifiedAt time.Time `gorm:"index" json:"modified_at"`
	Width      int       `json:"width"`
	Height     int       `json:"height"`
	Size       int64     `json:"size"`
	Checksum   string    `json:"checksum"`
	SourceID   string    `json:"source_id" gorm:"index"` // Original asset ID from device
	Latitude   float64   `json:"latitude"`
	Longitude  float64   `json:"longitude"`
	MimeType   string    `json:"mime_type"`
	IsDeleted  bool      `json:"is_deleted"`
}
