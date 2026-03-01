package models

import (
	"time"
)

// ShareType: one_time = view once then revoke, normal = ongoing access
const (
	ShareTypeOneTime = "one_time"
	ShareTypeNormal  = "normal"
)

type Share struct {
	ID                 string     `gorm:"primaryKey;type:text" json:"id"`
	SenderID           string     `gorm:"index;not null" json:"sender_id"`
	ReceiverID         string     `gorm:"index;not null" json:"receiver_id"`
	ImageID            string     `gorm:"index;not null" json:"image_id"`
	ShareType          string     `gorm:"not null" json:"share_type"` // one_time | normal
	EncryptedShareKey  string     `gorm:"type:text" json:"-"`         // base64, for receiver to decrypt image
	SenderPublicKey    string     `gorm:"type:text" json:"-"`         // base64, for receiver to decrypt share_key
	ViewedAt           *time.Time `json:"viewed_at,omitempty"`
	CreatedAt          time.Time  `json:"created_at"`
}
