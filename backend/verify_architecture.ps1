# Verification Script for New Architecture

Write-Host "Verifying new backend architecture..."

$baseUrl = "http://localhost:8080"
$userId = "testuser"
$imageId = "test-image-uuid-123"

# 1. Generate Upload URLs
$urlEndpoint = "$baseUrl/images/upload_urls"
$body = @{
    image_id = $imageId
    user_id = $userId
    variants = @("original", "thumb_256")
} | ConvertTo-Json

Write-Host "1. Testing GenerateUploadURLs..."
try {
    $response = Invoke-RestMethod -Uri $urlEndpoint -Method Post -Body $body -ContentType "application/json"
    Write-Host "Success! Got URLs:"
    $response.urls | Out-String | Write-Host
} catch {
    Write-Host "Error generating upload URLs: $_"
    exit 1
}

# 2. Register Image Metadata
$registerEndpoint = "$baseUrl/images/register"
$metadata = @{
    image_id = $imageId
    user_id = $userId
    width = 1920
    height = 1080
    size = 102400
    checksum = "dummy-checksum"
    is_deleted = $false
} | ConvertTo-Json

Write-Host "2. Testing RegisterImage..."
try {
    $response = Invoke-RestMethod -Uri $registerEndpoint -Method Post -Body $metadata -ContentType "application/json"
    Write-Host "Success! Registered image."
} catch {
    Write-Host "Error registering image: $_"
    exit 1
}

# 3. List Images
$listEndpoint = "$baseUrl/images?user_id=$userId"
Write-Host "3. Testing ListImages..."
try {
    $response = Invoke-RestMethod -Uri $listEndpoint -Method Get
    Write-Host "Success! Found $($response.images.Count) images."
    if ($response.images.Count -gt 0) {
        Write-Host "First image Original URL: $($response.images[0].original_url)"
    }
} catch {
    Write-Host "Error listing images: $_"
    exit 1
}

# 4. Sync Images
$syncEndpoint = "$baseUrl/sync?user_id=$userId"
Write-Host "4. Testing SyncImages..."
try {
    $response = Invoke-RestMethod -Uri $syncEndpoint -Method Get
    Write-Host "Success! Found $($response.updates.Count) updates."
} catch {
    Write-Host "Error syncing images: $_"
    exit 1
}

Write-Host "Verification Complete!"
