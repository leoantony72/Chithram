"""
evaluate_model.py — Proper face detection evaluation with NMS.

Evaluation data format (YOLO standard):
  backend/eval_data/test/images/  → image files
  backend/eval_data/test/labels/  → matching .txt label files
"""

import argparse
import os
import sys
import json
import glob
import numpy as np
from PIL import Image

def parse_args():
    parser = argparse.ArgumentParser(description='Evaluate ONNX face detection model (mAP)')
    parser.add_argument('--model', required=True, help='Path to ONNX model')
    parser.add_argument('--eval-dir', default=None, help='Path to eval_data directory')
    parser.add_argument('--iou-thresh', type=float, default=0.45, help='IoU threshold for TP')
    parser.add_argument('--conf-thresh', type=float, default=0.25, help='Confidence threshold')
    parser.add_argument('--nms-thresh', type=float, default=0.45, help='NMS threshold')
    return parser.parse_args()


def load_model(model_path):
    import onnx
    import onnxruntime as ort

    model = onnx.load(model_path)
    for node in model.graph.node:
        if node.op_type == "Reshape":
            new_attr = [a for a in node.attribute if a.name != "allowzero"]
            del node.attribute[:]
            node.attribute.extend(new_attr)

    model_bytes = model.SerializeToString()
    session = ort.InferenceSession(model_bytes, providers=['CPUExecutionProvider'])
    return session


def preprocess_image(image_path, input_size=(640, 640)):
    img = Image.open(image_path).convert('RGB')
    orig_w, orig_h = img.size
    img_resized = img.resize(input_size)
    img_array = np.array(img_resized).astype(np.float32) / 255.0
    img_array = np.transpose(img_array, (2, 0, 1))
    img_array = np.expand_dims(img_array, axis=0)
    return img_array, orig_w, orig_h


def box_iou(box1, box2):
    """Compute IoU of two [x1, y1, x2, y2] boxes."""
    xA = max(box1[0], box2[0])
    yA = max(box1[1], box2[1])
    xB = min(box1[2], box2[2])
    yB = min(box1[3], box2[3])
    inter = max(0, xB - xA) * max(0, yB - yA)
    area1 = (box1[2] - box1[0]) * (box1[3] - box1[1])
    area2 = (box2[2] - box2[0]) * (box2[3] - box2[1])
    union = area1 + area2 - inter
    return inter / union if union > 0 else 0.0


def nms(boxes, scores, iou_threshold):
    """Simple Non-Maximum Suppression."""
    if len(boxes) == 0:
        return []
    
    idxs = np.argsort(scores)[::-1]
    keep = []
    
    while len(idxs) > 0:
        i = idxs[0]
        keep.append(i)
        
        if len(idxs) == 1:
            break
            
        ious = np.array([box_iou(boxes[i], boxes[j]) for j in idxs[1:]])
        idxs = idxs[1:][ious < iou_threshold]
        
    return keep


def run_inference(session, img_tensor, conf_thresh, nms_thresh):
    input_name = session.get_inputs()[0].name
    outputs = session.run(None, {input_name: img_tensor})
    raw = outputs[0][0]  # [features, anchors]
    
    # YOLOv8 output: [x,y,w,h, conf...] or [x,y,w,h, face_conf, landmark...]
    if raw.shape[0] < 5: return []
    
    cx = raw[0]
    cy = raw[1]
    w = raw[2]
    h = raw[3]
    conf = raw[4] # For face-specific models, row 4 is usually the face confidence
    
    mask = conf > conf_thresh
    cx, cy, w, h, conf = cx[mask], cy[mask], w[mask], h[mask], conf[mask]
    
    if len(conf) == 0: return []
    
    boxes = []
    for i in range(len(conf)):
        x1 = cx[i] - w[i] / 2
        y1 = cy[i] - h[i] / 2
        x2 = cx[i] + w[i] / 2
        y2 = cy[i] + h[i] / 2
        boxes.append([x1, y1, x2, y2])
        
    keep = nms(np.array(boxes), conf, nms_thresh)
    
    results = []
    for i in keep:
        results.append(boxes[i] + [float(conf[i])])
    return results


def load_ground_truth(label_path, img_w, img_h):
    boxes = []
    if not os.path.exists(label_path): return []
    with open(label_path) as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) < 5: continue
            _, xc, yc, w, h = map(float, parts[:5])
            x1 = (xc - w / 2) * img_w
            y1 = (yc - h / 2) * img_h
            x2 = (xc + w / 2) * img_w
            y2 = (yc + h / 2) * img_h
            boxes.append([x1, y1, x2, y2])
    return boxes


def evaluate_dataset(session, images_dir, labels_dir, iou_thresh=0.5, conf_thresh=0.25, nms_thresh=0.45):
    image_paths = sorted(glob.glob(os.path.join(images_dir, '*.*')))
    image_paths = [p for p in image_paths if p.lower().endswith(('.jpg', '.jpeg', '.png'))]
    
    if not image_paths:
        return None, f"No images found in {images_dir}"

    all_tp, all_fp, all_fn = 0, 0, 0
    total_gt = 0
    conf_sum = 0
    det_count = 0

    for idx, img_path in enumerate(image_paths):
        if idx % 20 == 0:
            print(f"[eval] {idx}/{len(image_paths)} images processed...", file=sys.stderr)
            
        stem = os.path.splitext(os.path.basename(img_path))[0]
        label_path = os.path.join(labels_dir, stem + '.txt')

        img_tensor, orig_w, orig_h = preprocess_image(img_path)
        gt_boxes = load_ground_truth(label_path, orig_w, orig_h)
        total_gt += len(gt_boxes)

        dets = run_inference(session, img_tensor, conf_thresh, nms_thresh)
        
        # Scale to original image
        scale_x, scale_y = orig_w / 640.0, orig_h / 640.0
        scaled_dets = []
        for d in dets:
            scaled_dets.append([d[0]*scale_x, d[1]*scale_y, d[2]*scale_x, d[3]*scale_y, d[4]])
            conf_sum += d[4]
            det_count += 1

        matched_gt = set()
        for det in scaled_dets:
            best_iou = 0.0
            best_gt_idx = -1
            for j, gt in enumerate(gt_boxes):
                if j in matched_gt: continue
                cur_iou = box_iou(det[:4], gt)
                if cur_iou > best_iou:
                    best_iou = cur_iou
                    best_gt_idx = j
            
            if best_iou >= iou_thresh:
                all_tp += 1
                matched_gt.add(best_gt_idx)
            else:
                all_fp += 1
        
        all_fn += len(gt_boxes) - len(matched_gt)

    precision = all_tp / (all_tp + all_fp) if (all_tp + all_fp) > 0 else 0.0
    recall = all_tp / (all_tp + all_fn) if (all_tp + all_fn) > 0 else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0
    avg_conf = conf_sum / det_count if det_count > 0 else 0.0

    return {
        "accuracy": round(f1, 4),
        "avg_confidence": round(avg_conf, 4),
        "precision": round(precision, 4),
        "recall": round(recall, 4),
        "loss": round(1.0 - f1, 4),
        "total_images": len(image_paths),
        "total_gt_faces": total_gt,
        "true_positives": all_tp,
        "false_positives": all_fp,
        "false_negatives": all_fn,
        "status": "success"
    }, None

def main():
    args = parse_args()
    if not os.path.exists(args.model):
        print(json.dumps({"error": "Model not found", "status": "failed"}))
        sys.exit(1)

    try:
        session = load_model(args.model)
    except Exception as e:
        print(json.dumps({"error": str(e), "status": "failed"}))
        sys.exit(1)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    eval_dir = args.eval_dir or os.path.join(script_dir, "..", "eval_data", "test")
    images_dir = os.path.join(eval_dir, "images")
    labels_dir = os.path.join(eval_dir, "labels")

    result, err = evaluate_dataset(session, images_dir, labels_dir, 
                                   args.iou_thresh, args.conf_thresh, args.nms_thresh)
    if err:
        print(json.dumps({"error": err, "status": "failed"}))
        sys.exit(1)

    print(json.dumps(result))

if __name__ == "__main__":
    main()
