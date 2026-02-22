import sys
import cv2
import json
import os
import numpy as np

def run_onnx_yolov8_face(img, model_path):
    import onnxruntime as ort
    
    # Try using CPU provider
    session = ort.InferenceSession(model_path, providers=['CPUExecutionProvider'])
    input_name = session.get_inputs()[0].name
    
    # Preprocess
    img_h, img_w = img.shape[:2]
    target_size = 640
    scale = min(target_size / img_w, target_size / img_h)
    new_w, new_h = int(img_w * scale), int(img_h * scale)
    
    resized = cv2.resize(img, (new_w, new_h))
    
    # padding
    pad_w = target_size - new_w
    pad_h = target_size - new_h
    pad_left = pad_w // 2
    pad_right = pad_w - pad_left
    pad_top = pad_h // 2
    pad_bottom = pad_h - pad_top
    
    padded = cv2.copyMakeBorder(resized, pad_top, pad_bottom, pad_left, pad_right, cv2.BORDER_CONSTANT, value=(114, 114, 114))
    
    blob = padded.astype(np.float32) / 255.0
    blob = blob.transpose(2, 0, 1)
    blob = np.expand_dims(blob, axis=0) # [1, 3, 640, 640]
    
    # Infer
    outputs = session.run(None, {input_name: blob})
    out = outputs[0][0] # Output is [15, 8400] for yolov8n-face
    
    if out.shape[0] > out.shape[1]:
        out = out.T  # -> [8400, 15]
    else:
        out = out.T
        
    boxes = []
    scores = []
    landmarks_list = []
    
    for row in out:
        conf = float(row[4])
        if conf > 0.65:
            cx, cy, w, h = row[0:4]
            # scale back
            cx = (cx - pad_left) / scale
            cy = (cy - pad_top) / scale
            w = w / scale
            h = h / scale
            
            bx = cx - w / 2
            by = cy - h / 2
            
            boxes.append([int(bx), int(by), int(w), int(h)])
            scores.append(conf)
            
            if len(row) >= 15:
                # 5 landmarks (x, y)
                lmks = []
                for j in range(5):
                    lx = (row[5 + j*2] - pad_left) / scale
                    ly = (row[5 + j*2 + 1] - pad_top) / scale
                    lmks.append([int(lx), int(ly)])
                landmarks_list.append(lmks)
            
    # OpenCV NMS
    results = []
    if len(boxes) > 0:
        indices = cv2.dnn.NMSBoxes(boxes, scores, score_threshold=0.5, nms_threshold=0.4)
        for i in indices.flatten():
            box = boxes[i]
            x, y, w, h = box[0], box[1], box[2], box[3]
            
            # Default fallback for eyes if landmarks are missing
            le_pt = [int(x + w * 0.3), int(y + h * 0.4)]
            re_pt = [int(x + w * 0.7), int(y + h * 0.4)]

            if i < len(landmarks_list) and len(landmarks_list[i]) >= 2:
                lmk = landmarks_list[i]
                le_pt = [int(lmk[0][0]), int(lmk[0][1])]
                re_pt = [int(lmk[1][0]), int(lmk[1][1])]
                
            results.append({
                'box': [int(x), int(y), int(w), int(h)],
                'left_eye': le_pt,
                'right_eye': re_pt
            })
    return results

def detect_faces(img_path, model_path=None):
    img = cv2.imread(img_path)
    if img is None:
        print(json.dumps([]))
        return

    # 1. Attempt ONNX Inference (YOLOv8-Face) first 
    if model_path and os.path.exists(model_path):
        try:
            results = run_onnx_yolov8_face(img, model_path)
            print(json.dumps(results))
            return
        except Exception as e:
            pass

    # 2. Fallback to classical OpenCV Haarcascades
    face_cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
    eye_cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_eye.xml')
    
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    
    faces = face_cascade.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(20, 20))
    
    results = []
    for (x, y, w, h) in faces:
        face_roi = gray[y:y+h, x:x+w]
        eyes = eye_cascade.detectMultiScale(face_roi)
        
        le = None
        re = None
        
        if len(eyes) >= 2:
            e1, e2 = eyes[0], eyes[1]
            if e1[0] < e2[0]:
                le, re = e1, e2
            else:
                le, re = e2, e1
                
            lx, ly, lw, lh = le
            rx, ry, rw, rh = re
            le_pt = [int(x + lx + lw//2), int(y + ly + lh//2)]
            re_pt = [int(x + rx + rw//2), int(y + ry + rh//2)]
        else:
            le_pt = [int(x + w * 0.3), int(y + h * 0.4)]
            re_pt = [int(x + w * 0.7), int(y + h * 0.4)]
            
        results.append({
            'box': [int(x), int(y), int(w), int(h)],
            'left_eye': le_pt,
            'right_eye': re_pt
        })
        
    print(json.dumps(results))

if __name__ == '__main__':
    img_path = sys.argv[1] if len(sys.argv) > 1 else None
    model_path = sys.argv[2] if len(sys.argv) > 2 else None
    
    if img_path:
        detect_faces(img_path, model_path)
    else:
        print(json.dumps([]))
