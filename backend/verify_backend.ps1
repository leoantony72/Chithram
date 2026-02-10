# Verification Script

This script will verification the backend endpoints.

## Instructions
1.  Make sure you are in the `backend` directory.
2.  Run `mkdir models` if it doesn't exist.
3.  Create a dummy ONNX file: `echo "dummy content" > models/face-detection.onnx`
4.  Run the server: `go run main.go` in one terminal.
5.  Run this script or the curl commands in another terminal.

## Script (verify_backend.ps1 - PowerShell)

```powershell
# Create dummy model
mkdir -Force models
"dummy model content" | Out-File -FilePath models/face-detection.onnx -Encoding ASCII

# Start server in background (manual step preferred for now)
Write-Host "Please ensure 'go run main.go' is running in another terminal."

# Test Info Endpoint
$infoUrl = "http://localhost:8080/models/face-detection/info"
Write-Host "Testing Info Endpoint: $infoUrl"
try {
    $response = Invoke-RestMethod -Uri $infoUrl -Method Get
    Write-Host "Response: $($response | ConvertTo-Json)"
} catch {
    Write-Host "Error accessing info endpoint: $_"
}

# Test Download Endpoint
$downloadUrl = "http://localhost:8080/models/face-detection/download"
Write-Host "Testing Download Endpoint: $downloadUrl"
$outFile = "downloaded_model.onnx"
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $outFile
    if (Test-Path $outFile) {
        Write-Host "Download successful: $outFile"
        Remove-Item $outFile
    } else {
        Write-Host "Download failed: File not found."
    }
} catch {
    Write-Host "Error accessing download endpoint: $_"
}

# Clean up
Remove-Item models/face-detection.onnx
```
