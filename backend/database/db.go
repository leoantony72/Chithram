package database

import (
	"log"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

var DB *gorm.DB

func Connect() {
	var err error
	DB, err = gorm.Open(sqlite.Open("chithram.db"), &gorm.Config{})
	if err != nil {
		log.Fatal("Failed to connect to database!", err)
	}

	log.Println("Database connection established")
}
