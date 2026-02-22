import sys
import os
import sqlite3
import numpy as np

try:
    import torch
    import torch.nn as nn
    import torch.optim as optim
    from torchvision import transforms
    from torch.utils.data import Dataset, DataLoader
    import cv2
    import onnx
    from onnx2torch import convert
    import shutil
    import re
    import io
except ImportError:
    print("Missing ML libraries. Waiting for background pip install to finish...")
    print("Please ensure: pip install torch torchvision opencv-python onnx2torch onnx onnxscript")
    sys.exit(1)

import warnings
warnings.filterwarnings("ignore")

# Fix Windows console encoding issues for emojis and special chars
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except (AttributeError, io.UnsupportedOperation):
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
        sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')

# Force legacy behavior and clean console
os.environ['TORCH_ONNX_LEGACY_EXPORT'] = '1'
try:
    import torch._dynamo
    torch._dynamo.disable()
except:
    pass

# ----- Contrastive Loss (SimCLR / NT-Xent structure) -----
class NTXentLoss(nn.Module):
    def __init__(self, temperature=0.5):
        super().__init__()
        self.temperature = temperature
        self.cosine_similarity = nn.CosineSimilarity(dim=-1)

    def forward(self, z_i, z_j):
        batch_size = z_i.shape[0]
        z = torch.cat([z_i, z_j], dim=0)
        
        sim = self.cosine_similarity(z.unsqueeze(1), z.unsqueeze(0)) / self.temperature
        
        # Positive pairs
        sim_i_j = torch.diag(sim, batch_size)
        sim_j_i = torch.diag(sim, -batch_size)
        positives = torch.cat([sim_i_j, sim_j_i], dim=0)
        
        # Mask out self-similarity
        mask = (~torch.eye(2 * batch_size, 2 * batch_size, dtype=torch.bool, device=z.device)).float()
        
        nominator = torch.exp(positives)
        denominator = mask * torch.exp(sim)
        
        loss = -torch.log(nominator / torch.sum(denominator, dim=1))
        return torch.mean(loss)

# ----- Datasets (Reading localized SQLite photos directly) -----
class FederatedLocalFacesDataset(Dataset):
    def __init__(self, db_path, img_size=(640, 640), cache_dir=None):
        self.db_path = os.path.abspath(db_path)
        self.img_size = img_size
        self.cache_dir = cache_dir
        
        print(f"DEBUG: Connecting to SQLite at: {self.db_path}")
        if not os.path.exists(self.db_path):
            print(f"STATUS: ERROR-Database file not found at {self.db_path}. Training aborted.")
            sys.exit(2)
            
        # Connect with WAL mode and timeout to handle locks
        self.conn = sqlite3.connect(self.db_path, timeout=30.0)
        self.cursor = self.conn.cursor()
        try:
            self.cursor.execute("PRAGMA journal_mode=WAL")
            self.cursor.execute("PRAGMA synchronous=NORMAL")
        except: pass
        
        try:
            # 1. Check total potential targets regardless of training status
            self.cursor.execute("SELECT count(*) FROM faces WHERE bbox IS NOT NULL")
            self.total_local_faces = self.cursor.fetchone()[0]

            # 2. Fetch only UNTRAINED faces (fl_trained = 0) to avoid overfitting
            self.cursor.execute("SELECT id, image_path, bbox FROM faces WHERE bbox IS NOT NULL AND fl_trained = 0 ORDER BY id ASC LIMIT 40")
            self.rows = self.cursor.fetchall()
            
            if len(self.rows) > 0:
                ids = [r[0] for r in self.rows]
                print(f"STATUS: Selected {len(self.rows)} faces for training. ID Range: {min(ids)} to {max(ids)}")
            elif self.total_local_faces > 0:
                print(f"STATUS: All {self.total_local_faces} local face entries have already been used for training.")
        except Exception as e:
            print(f"Warning: Database error: {e}")
            self.rows = []
            self.total_local_faces = 0

        # View 1: Standard Augmented Geometry
        self.transform1 = transforms.Compose([
            transforms.ToPILImage(),
            transforms.Resize(img_size),
            transforms.RandomHorizontalFlip(p=0.5),
            transforms.ColorJitter(0.2, 0.2, 0.2, 0.1),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.5,0.5,0.5], std=[0.5,0.5,0.5])
        ])
        
        # View 2: High Augmentation Distillation
        self.transform2 = transforms.Compose([
            transforms.ToPILImage(),
            transforms.Resize(img_size),
            transforms.RandomHorizontalFlip(p=0.5),
            transforms.ColorJitter(0.3, 0.3, 0.3, 0.1),
            transforms.RandomGrayscale(p=0.2),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.5,0.5,0.5], std=[0.5,0.5,0.5])
        ])

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, idx):
        face_id, img_path, bbox_str = self.rows[idx]
        
        load_path = img_path
        if img_path.startswith('cloud_') and self.cache_dir:
            image_id = img_path[6:]
            load_path = os.path.join(self.cache_dir, f"{image_id}.jpg")

        img = cv2.imread(load_path)
        
        if img is None:
            # Fallback for missing local files or cache misses
            print(f"Warning: Could not read image at {load_path}")
            return torch.zeros(3, self.img_size[0], self.img_size[1]), torch.zeros(3, self.img_size[0], self.img_size[1])
        else:
            img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
            try:
                # Handle Flutter's Rect format string: "Rect.fromLTRB(l, t, r, b)" or raw "x,y,w,h"
                import re
                nums = re.findall(r"[-+]?\d*\.\d+|\d+", bbox_str)
                if len(nums) == 4:
                    vals = [float(n) for n in nums]
                    if "Rect.fromLTRB" in bbox_str:
                        # Convert LTRB -> XYWH
                        l, t, r, b = vals
                        x1, y1, x2, y2 = int(l), int(t), int(r), int(b)
                    else:
                        # Assume XYWH
                        x, y, w, h = vals
                        x1, y1, x2, y2 = int(x), int(y), int(x+w), int(y+h)
                    
                    h_img, w_img, _ = img.shape
                    x1, y1 = max(0, x1), max(0, y1)
                    x2, y2 = min(w_img, x2), min(h_img, y2)
                    
                    # Crop actual sub-face
                    if x2 > x1 and y2 > y1:
                        img = img[y1:y2, x1:x2]
            except Exception as e:
                print(f"Warning: BBox parse error for '{bbox_str}': {e}")
                pass

        return self.transform1(img), self.transform2(img)

    def mark_all_trained(self):
        ids = [row[0] for row in self.rows]
        if not ids: return
        try:
            placeholders = ','.join(['?'] * len(ids))
            self.cursor.execute(f"UPDATE faces SET fl_trained = 1 WHERE id IN ({placeholders})", ids)
            self.conn.commit()
            
            # Verify the update actually persisted
            self.cursor.execute(f"SELECT count(*) FROM faces WHERE id IN ({placeholders}) AND fl_trained = 1", ids)
            confirmed = self.cursor.fetchone()[0]
            print(f"STATUS: Database Update Verified: {confirmed}/{len(ids)} faces recorded as trained.")
            
            if confirmed < len(ids):
                print(f"STATUS: WARNING-Persistence Failure. Only {confirmed} of {len(ids)} records were updated. Database may be locked.")
        except Exception as e:
            print(f"STATUS: CRITICAL-Database Lock/Error during training status update: {e}")

    def close(self):
        try:
            self.conn.close()
        except: pass

def train_local_ssl(model_path, output_path, db_path, cache_dir=None, epochs=1):
    print(f"Loading ONNX base model from {model_path}...")
    
    # 1. Convert downloaded generic ONNX model back to active PyTorch graph using onnx2torch
    onnx_model = onnx.load(model_path)
    try:
        pytorch_model = convert(onnx_model)
    except Exception as e:
        print(f"Failed to dynamically map ONNX into PyTorch graph: {e}")
        import shutil
        shutil.copy(model_path, output_path)
        sys.exit(0)
        
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    pytorch_model.train()
    pytorch_model.to(device)

    # 2. SELECTIVE FREEZING: Protect the Box Regression Head
    # In YOLOv8, 'cv2' is Box Regression, 'cv3' is Classification/Score.
    # We freeze 'cv2' and 'dfl' so the model NEVER forgets how to draw boxes,
    # but let 'cv3' and the Backbone learn to recognize specific faces.
    frozen_count = 0
    trainable_count = 0
    for name, param in pytorch_model.named_parameters():
        if any(x in name for x in ['cv2', 'dfl']):
            param.requires_grad = False
            frozen_count += 1
        else:
            param.requires_grad = True
            trainable_count += 1
    
    print(f"STATUS: Layer Protection Active. Frozen: {frozen_count} (Box/DFL), Trainable: {trainable_count} (Backbone/Conf)")

    # 3. Local SSL Face dataset - Use 640x640 to avoid hardcoded Reshape errors in YOLOv8 nodes
    dataset = FederatedLocalFacesDataset(db_path, img_size=(640, 640), cache_dir=cache_dir)
    
    if len(dataset) < 2:
        if dataset.total_local_faces == 0:
            print(f"Error: No valid local faces found in {db_path}. Please 'Scan Local Photos' on the People page first.")
            sys.exit(2) 
        else:
            print(f"Status: Training skipped. All {dataset.total_local_faces} local face patches have already been trained. No new data available.")
            sys.exit(3) # Exit code 3 for 'Already Trained - Nothing to do'        
    # CRITICAL: Use batch_size=1. Many YOLOv8 models are exported with hardcoded 'reshape(1, ...)' 
    # logic in their output layers. Training with batch_size=2 results in shape mismatch errors.
    batch_sz = 1
    dataloader = DataLoader(dataset, batch_size=batch_sz, shuffle=True, drop_last=True)
    
    # 3. Create SSL Loop setup
    optimizer = optim.Adam(pytorch_model.parameters(), lr=5e-5) 
    criterion = NTXentLoss(temperature=0.5)

    print(f"STATUS: Starting Genuine Self-Supervised Edge Training on {len(dataset)} valid local image patches.")
    
    for epoch in range(epochs):
        epoch_loss = 0.0
        for i, (view1, view2) in enumerate(dataloader):
            # Format progress for Flutter UI
            print(f"PROGRESS: {i+1}/{len(dataloader)}")
            view1, view2 = view1.to(device), view2.to(device)
            optimizer.zero_grad()
            
            try:
                # YOLOv8 often outputs a list of feature maps or flattened detections
                out1 = pytorch_model(view1)
                out2 = pytorch_model(view2)
                
                # Robust output processing for varied architectures (Detection vs Recognition)
                def get_pooled_out(model_out):
                    if isinstance(model_out, (tuple, list)):
                        # If multi-head, flatten and cat all heads
                        parts = []
                        for o in model_out:
                            if isinstance(o, torch.Tensor):
                                # Global average pool if spatial, else just flatten
                                if len(o.shape) == 4:
                                    parts.append(torch.mean(o, dim=(2, 3)))
                                else:
                                    parts.append(o.reshape(o.size(0), -1))
                        return torch.cat(parts, dim=1) if len(parts) > 1 else parts[0]
                    else:
                        if len(model_out.shape) == 4:
                            return torch.mean(model_out, dim=(2, 3))
                        return model_out.reshape(model_out.size(0), -1)

                z1 = get_pooled_out(out1)
                z2 = get_pooled_out(out2)
                
                loss = criterion(z1, z2)
                loss.backward()
                optimizer.step()
                
                epoch_loss += loss.item()
            except Exception as e:
                # Provide better debug info for shape mismatches
                if 'out1' in locals():
                    if isinstance(out1, (list, tuple)):
                        shapes = [o.shape if torch.is_tensor(o) else type(o) for o in out1]
                    else:
                        shapes = out1.shape
                    print(f"DEBUG: Model Output Shapes: {shapes}")
                print(f"Math pass failed for generic architecture: {e}")
                break
                
        if epoch_loss != 0:
            print(f"STATUS: Epoch [{epoch+1}/{epochs}] complete. Average Loss: {epoch_loss/len(dataloader):.4f}")
            # Mark these images as trained so we don't duplicate effort next time
            dataset.mark_all_trained()
    
    dataset.close()

    # 4. Save and Back-Translate
    print(f"STATUS: Self-Supervised Local training loop complete. Injecting weights into ONNX...")
    pytorch_model.eval()
    
    try:
        # Load the original ONNX model to use as a template
        base_onnx = onnx.load(model_path)
        state_dict = pytorch_model.state_dict()
        
        # Helper to normalize names for matching
        def normalize_name(name):
            # 1. Standardize separators
            n = name.replace('/', '.').strip('.')
            # 2. Remove common prefixes
            if n.startswith('model.'): n = n[6:]
            if n.startswith('model'): n = n[5:] if n.startswith('model.') else n[5:]
            # 3. Handle onnx2torch 'Conv' nesting (model.0.conv.Conv.weight -> 0.conv.weight)
            n = n.replace('.Conv.', '.').replace('.conv.', '.')
            # 4. Remove final redundancy
            n = n.replace('.weight', '').replace('.bias', '')
            return n.strip('.')

        # Pre-process state_dict to have normalized keys
        normalized_state = {normalize_name(k): v for k, v in state_dict.items()}
        
        updated_count = 0
        for initializer in base_onnx.graph.initializer:
            # We also need the type of parameter (weight vs bias) to distinguish matches
            init_type = 'weight' if 'weight' in initializer.name.lower() else 'bias'
            norm_init_name = normalize_name(initializer.name)
            
            # Find a match in the state_dict
            match_found = False
            for state_key, param_val in state_dict.items():
                if normalize_name(state_key) == norm_init_name:
                    # Check if both are weights or both are biases
                    state_type = 'weight' if 'weight' in state_key.lower() else 'bias'
                    if init_type != state_type: continue
                    
                    param = param_val.detach().cpu().numpy()
                    if list(initializer.dims) == list(param.shape):
                        initializer.raw_data = param.tobytes()
                        updated_count += 1
                        match_found = True
                        break
                    elif list(initializer.dims) == list(param.shape[::-1]):
                        initializer.raw_data = param.T.copy().tobytes()
                        updated_count += 1
                        match_found = True
                        break
        
        onnx.save(base_onnx, output_path)
        print(f"STATUS: Successfully injected {updated_count} trained parameter sets into ONNX.")
        if updated_count < 10:
            print("DEBUG: Logic failed. Standardizing names did not find enough matches.")
            print("DEBUG: Final StateDict Match Key (sample):", list(normalized_state.keys())[:5])
            print("DEBUG: Final ONNX Match Key (sample):", [normalize_name(i.name) for i in base_onnx.graph.initializer[:5]])
        print("STATUS: ONNX Edge Training Artifact saved.")
    except Exception as e:
        print(f"STATUS: Weight injection failed: {e}")
        import shutil
        shutil.copy(model_path, output_path)

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python desktop_train.py <input.onnx> <output.onnx> <chithram_faces.db path> [cache_dir]")
        sys.exit(1)
        
    model_path = sys.argv[1]
    output_path = sys.argv[2]
    db_path = sys.argv[3]
    cache_dir = sys.argv[4] if len(sys.argv) > 4 else None
    
    train_local_ssl(model_path, output_path, db_path, cache_dir=cache_dir, epochs=1)
