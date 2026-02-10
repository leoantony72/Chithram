# Face Detection & Recognition Models

This directory stores the ONNX models served by the backend.

## 1. Face Detection Model (YOLOv8n-face)
For mobile applications, we recommend the **YOLOv8n-face (Nano)** model.
- **Why?**: Smallest and fastest version of YOLOv8, ideal for mobile.

### Download Instructions
1.  **Download**: [yolov8n-face.onnx](https://github.com/lindevs/yolov8-face/releases/download/v1.0.0/yolov8n-face.onnx)
2.  **Rename**: `face-detection.onnx`
3.  **Place in**: `backend/models/`

---

## 2. Face Recognition Model (MobileFaceNet)
For generating unique face embeddings, we recommend **MobileFaceNet** (specifically the `w600k_mbf` version from InsightFace's buffalo_s model pack).
- **Why?**: Extremely lightweight (< 15MB) and highly accurate for mobile face verification.

### Download Instructions
1.  **Download**: [w600k_mbf.onnx](https://github.com/deepghs/insightface/raw/master/buffalo_s/w600k_mbf.onnx) (Direct Link)
    *   *Alternative Source*: [HuggingFace - deepghs/insightface/buffalo_s](https://huggingface.co/deepghs/insightface/tree/main/buffalo_s)
2.  **Rename**: `face-recognition.onnx`
3.  **Place in**: `backend/models/`

---

## Final Directory Structure
```
backend/
└── models/
    ├── face-detection.onnx   (originally yolov8n-face.onnx)
    └── face-recognition.onnx (originally w600k_mbf.onnx)
```
