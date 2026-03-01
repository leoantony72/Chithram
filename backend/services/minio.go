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

var MinioClient *minio.Client       // Internal client — used for backend file operations
var publicMinioClient *minio.Client // Public client — used ONLY for generating pre-signed URLs

var Endpoint string        // Internal MinIO address (e.g. localhost:9000)
var PublicMinioHost string // Public address clients use to reach MinIO (e.g. 192.168.18.11:9000)

const (
	AccessKeyID     = "minioadmin"
	SecretAccessKey = "minioadmin"
	UseSSL          = false
	BucketName      = "images"
)

func InitMinio() {
	var err error

	Endpoint = os.Getenv("MINIO_HOST")
	if Endpoint == "" {
		Endpoint = "localhost:9000"
	}

	// PUBLIC_MINIO_HOST: the address Android/web clients use to access MinIO directly.
	// When set, pre-signed URLs are generated using this address so the HMAC signature
	// is valid for the public hostname — NOT rewritten after signing (which breaks sigs).
	PublicMinioHost = os.Getenv("PUBLIC_MINIO_HOST")
	if PublicMinioHost == "" {
		PublicMinioHost = Endpoint
	}

	// Internal client — for all backend-to-MinIO operations (upload, download, list)
	MinioClient, err = minio.New(Endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(AccessKeyID, SecretAccessKey, ""),
		Secure: UseSSL,
	})
	if err != nil {
		log.Fatalln(err)
	}

	// Public client — for generating pre-signed URLs that clients can actually reach.
	// Uses the same credentials but signs with the public hostname from the start.
	if PublicMinioHost != Endpoint {
		publicMinioClient, err = minio.New(PublicMinioHost, &minio.Options{
			Creds:  credentials.NewStaticV4(AccessKeyID, SecretAccessKey, ""),
			Secure: UseSSL,
		})
		if err != nil {
			log.Printf("Warning: Could not create public MinIO client for %s: %v. Falling back to internal client.", PublicMinioHost, err)
			publicMinioClient = MinioClient
		}
	} else {
		publicMinioClient = MinioClient
	}

	log.Printf("MinIO: internal=%s, public=%s\n", Endpoint, PublicMinioHost)

	// Create bucket if it doesn't exist (use internal client)
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

// GetPresignedURL generates a presigned GET URL using the public client so the
// hostname in the signature matches what clients will actually connect to.
func GetPresignedURL(objectName string, expiry time.Duration) (string, error) {
	ctx := context.Background()
	reqParams := make(url.Values)

	presignedURL, err := publicMinioClient.PresignedGetObject(ctx, BucketName, objectName, expiry, reqParams)
	if err != nil {
		return "", err
	}
	return presignedURL.String(), nil
}

// GetPresignedPutURL generates a presigned PUT URL using the public client.
func GetPresignedPutURL(objectName string, expiry time.Duration) (string, error) {
	ctx := context.Background()
	presignedURL, err := publicMinioClient.PresignedPutObject(ctx, BucketName, objectName, expiry)
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
