# Chithram: Technical Architecture & Deep Dive

Chithram is a privacy-first, AI-powered image management and storage platform. Built with a **zero-knowledge architecture**, it ensures that your data remains yours, even when stored in the cloud. This document provides a comprehensive technical exploration into its core components, privacy-preserving technologies, and cryptographic protocols.

---

## 🛡️ 1. Security & Privacy Architecture

### End-to-End Encryption (E2E)
Chithram utilizes a strict zero-knowledge design. The server acts as a blind storage and metadata orchestrator, never seeing the raw image data or the master encryption keys.

- **Key Derivation (Argon2id)**: 
  The platform uses **Argon2id** (via Libsodium's `crypto_pwhash`) to derive a 256-bit **High-Entropy Master Key** from the user's password. 
  - **Memory Limit**: `memLimitInteractive` (~64MB)
  - **Ops Limit**: `opsLimitInteractive` (Iterative hashing)
  - **Salt**: A unique, random 16-byte salt is generated during signup and stored on the server.
- **Symmetric Encryption (XChaCha20-Poly1305)**: 
  All asset variants (Originals, 1024px, 256px, 64px) are encrypted client-side using `crypto_secretbox_easy`.
  - **Algorithm**: XChaCha20 (256-bit key) with Poly1305 MAC for Authenticated Encryption with Associated Data (AEAD).
  - **Nonce Management**: A unique 24-byte nonce is generated for every single file. This nonce is prepended to the ciphertext before upload.
- **Upload Flow**: 
  Encrypted payloads are PUT directly to **MinIO** via presigned URLs. The server only receives metadata (checksums, file sizes, image IDs) after a successful upload.

### Secure Sharing Protocol (Asymmetric Cryptography)
Sharing in Chithram does not compromise the E2E guarantee. We use a "Zero-Transfer" security model.

- **Asymmetric Exchange (Sodium `crypto_box_seal`)**: 
  To share an image, the sender uses the recipient's **Curve25519 Public Key**.
- **The Flow**:
  1. **Ephemeral Key Creation**: The sender generates a one-time random `shareKey` for the specific image.
  2. **Content Encryption**: The image is encrypted with this `shareKey` using symmetric encryption (XChaCha20).
  3. **Anonymous Sealed Box**: The `shareKey` itself is encrypted (sealed) using the recipient's public key. This "sealed box" is anonymous; only the recipient can open it using their private key.
  4. **Recipient Access**: The recipient fetches the sealed box, unseals it to recover the `shareKey`, and then decrypts the image data.

---

## 🧠 2. Privacy-Preserving AI

### Federated Learning (FL)
Chithram allows global AI models to improve without ever centralizing raw user data. We implement a local training loop on the client devices.

- **Local Training Loop**:
  - **Windows/Desktop**: Spawns a sandboxed Python process using a `.venv` to run `desktop_train.py`. It uses `torch` or `onnx` backends to calculate gradients against the local decrypted face database.
  - **Mobile**: Uses the `fl_training_plugin` to leverage on-device acceleration (CoreML/NNAPI) for training.
- **Update Protocol**:
  Clients compute a "Local Update" (weight deltas). These deltas are sent to the backend via `POST /fl/update`.
- **Server-Side Aggregation (FedAvg)**:
  The Go backend orchestrates the **Federated Averaging (FedAvg)** algorithm. Once a sufficient number of updates are received, the `fl_aggregator.go` service combines them into a new **Global Model** (`.onnx`), which is then served back to all clients.

### Smart Face Recognition & Clustering
Face processing happens entirely on the client, leveraging hardware-accelerated inference.

- **Detection & Embedding (RetinaFace/FaceNet)**: 
  The app uses native ONNX models for real-time face detection and 128/512-dimensional embedding generation. 
- **Distance-Based Clustering**:
  Embeddings are compared using **Euclidean Distance**. If the distance between two faces is below a specific threshold (e.g., 0.6), they are assigned to the same user-defined or system-generated cluster.
- **Encrypted Sync**:
  Face clusters and representative thumbnails are synced to the cloud as an encrypted large-blob. This allows a user to sign in on a new device and immediately see their recognized "People" section without re-scanning thousands of photos.

---

## 🔍 3. Intelligent Search & Organization

### Semantic Search (CLIP Architecture)
Search your photos using natural language concepts like "dog in a park" or "snowy mountains."

- **MobileCLIP2-S0 Implementation**:
  We use a lightweight, distilled version of the CLIP (Contrastive Language-Image Pre-training) model.
- **Multi-Modal Alignment**:
  1. **Image Branch**: Photos are processed into 512-dimensional vector embeddings during initial indexing.
  2. **Text Branch**: The user's query is tokenized using a **Byte-Pair Encoding (BPE)** tokenizer and passed through the text encoder.
  3. **Relevance Calculation**: We perform a **Dot Product** or **Cosine Similarity** between the text vector and all image vectors in the local SQLite database.
- **Performance**: Embeddings are indexed using a simple flat-index in SQLite or a specialized vector-store implementation for fast retrieval.

### Smart Journeys & Geo-Spatial Clustering
Chithram automatically organizes your timeline into "Journeys" using spatial and temporal data.

- **Clustering Logic**:
  Images are grouped into a "Journey" if they were taken within a specific timeframe (e.g., 4 days) and within a specific geographic radius.
- **Reverse Geocoding with Nominatim**:
  - **Caching**: We implement a local cache in `SharedPreferences` to avoid redundant API calls to OpenStreetMap.
  - **Privacy Masking**: Lat/Long coordinates are rounded to **2 decimal places** (~1.1km accuracy) before caching. This prevents the exact coordinate from being linked to a generic place name in the local database.

---

## 🏗️ 4. System Components

| Component | Technical Detail |
| :--- | :--- |
| **Flutter UI** | Uses `Provider` for state and `sqflite` for local metadata persistence. |
| **Go Backend** | A high-performance Gin-based API handling metadata, sync, and FL aggregation. |
| **MinIO** | High-performance, S3-compatible object storage for encrypted binaries. |
| **ONNX Runtime** | The universal engine for running AI models across Android, iOS, and Windows. |
| **Libsodium** | The gold standard for modern, easy-to-use cryptography. |
| **Photo Manager** | Native integration for efficient local gallery scanning and asset retrieval. |

---

## 🛠️ 5. Deployment & workflows

The project includes automated workflows for common tasks:
- **Build Android APK**: Located in `.agent/workflows/build_android_apk.md`.
- **Backend Setup**: See `/backend/readme.md` for Go server and MinIO configuration.
- **Model Management**: Scripts in `scripts/` and `/backend/scripts/` handle model export, conversion, and quantization.
