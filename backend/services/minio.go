package services

import (
	"context"
	"io"
	"log"
	"net/url"
	"os"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

var MinioClient *minio.Client

var Endpoint string // Reachable from Android units on LAN
const (
	AccessKeyID     = "minioadmin"
	SecretAccessKey = "minioadmin"
	UseSSL          = false
	BucketName      = "images"
)

func InitMinio() {
	var err error

	// Read dynamic endpoint from environment or default to localhost
	Endpoint = os.Getenv("MINIO_HOST")
	if Endpoint == "" {
		Endpoint = "localhost:9000"
	}

	// Initialize minio client object.
	MinioClient, err = minio.New(Endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(AccessKeyID, SecretAccessKey, ""),
		Secure: UseSSL,
	})
	if err != nil {
		log.Fatalln(err)
	}

	log.Printf("MinIO Client initialized successfully to %s\n", Endpoint)

	// Create bucket if it doesn't exist
	ctx := context.Background()
	exists, err := MinioClient.BucketExists(ctx, BucketName)
	if err != nil {
		log.Fatalln(err)
	}
	if !exists {
		err = MinioClient.MakeBucket(ctx, BucketName, minio.MakeBucketOptions{})
		if err != nil {
			log.Fatalln(err)
		}
		log.Printf("Successfully created bucket %s\n", BucketName)
	}
}

// UploadToMinio uploads a file reader to the specified path in MinIO
func UploadToMinio(objectName string, reader io.Reader, objectSize int64, contentType string) (minio.UploadInfo, error) {
	ctx := context.Background()
	info, err := MinioClient.PutObject(ctx, BucketName, objectName, reader, objectSize, minio.PutObjectOptions{
		ContentType: contentType,
	})
	if err != nil {
		return minio.UploadInfo{}, err
	}
	return info, nil
}

// ListFiles returns a list of object keys for a given prefix
func ListFiles(prefix string) ([]string, error) {
	ctx := context.Background()
	var files []string

	// List objects
	objectCh := MinioClient.ListObjects(ctx, BucketName, minio.ListObjectsOptions{
		Prefix:    prefix + "/",
		Recursive: true,
	})

	for object := range objectCh {
		if object.Err != nil {
			return nil, object.Err
		}
		files = append(files, object.Key)
	}
	return files, nil
}

// GetPresignedURL generates a presigned URL for a file
func GetPresignedURL(objectName string, expiry time.Duration) (string, error) {
	ctx := context.Background()
	reqParams := make(url.Values)
	// reqParams.Set("response-content-disposition", "attachment; filename=\"your-filename.txt\"")

	presignedURL, err := MinioClient.PresignedGetObject(ctx, BucketName, objectName, expiry, reqParams)
	if err != nil {
		return "", err
	}
	return presignedURL.String(), nil
}

// GetPresignedPutURL generates a presigned URL for uploading a file
func GetPresignedPutURL(objectName string, expiry time.Duration) (string, error) {
	ctx := context.Background()
	presignedURL, err := MinioClient.PresignedPutObject(ctx, BucketName, objectName, expiry)
	if err != nil {
		return "", err
	}
	return presignedURL.String(), nil
}

// DeleteObject deletes an object from the MinIO bucket
func DeleteObject(objectName string) error {
	ctx := context.Background()
	opts := minio.RemoveObjectOptions{
		GovernanceBypass: true,
	}
	return MinioClient.RemoveObject(ctx, BucketName, objectName, opts)
}

// DownloadFromMinio returns an object from MinIO as a reader
func DownloadFromMinio(objectName string) (*minio.Object, error) {
	ctx := context.Background()
	return MinioClient.GetObject(ctx, BucketName, objectName, minio.GetObjectOptions{})
}
