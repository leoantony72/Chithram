import argparse
import os
import sys
import torch
import onnx
from onnx2torch import convert
import io

# Fix Windows console encoding issues for emojis and special chars
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except (AttributeError, io.UnsupportedOperation):
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
        sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')

def average_state_dicts(state_dicts):
    """
    Computes the element-wise average of PyTorch state dictionaries via FedAvg.
    """
    if not state_dicts:
        return {}
    
    avg_state_dict = {}
    keys = state_dicts[0].keys()
    num_models = len(state_dicts)
    
    for key in keys:
        # Avoid averaging non-floating point tensors indiscriminately if they represent structural counts
        is_float = state_dicts[0][key].is_floating_point()
        
        # Sum up weights for this key across all models
        total = torch.zeros_like(state_dicts[0][key], dtype=torch.float64 if is_float else torch.int64)
        count = 0 
        
        for sd in state_dicts:
            if key in sd:
                # Need to move all to same device (CPU) just in case
                total += sd[key].to('cpu')
                count += 1
            else:
                print(f"Warning: Weight {key} missing in one of the models")
        
        if count > 0:
            if is_float:
                avg_state_dict[key] = (total / count).to(state_dicts[0][key].dtype)
            else:
                # For integers (like num_batches_tracked), averaging might not make sense, 
                # but typically FedAvg just takes standard mean or matches the latest.
                avg_state_dict[key] = (total // count).to(state_dicts[0][key].dtype)
                
    return avg_state_dict

def main():
    parser = argparse.ArgumentParser(description='Aggregate PyTorch .pth models and export to ONNX')
    parser.add_argument('models', nargs='+', help='List of .pth model paths to aggregate')
    parser.add_argument('--output', required=True, help='Path to save the aggregated .onnx model')
    parser.add_argument('--base_model', required=True, help='Path to the base .onnx model to define the architecture')
    
    args = parser.parse_args()
    
    if not args.models:
        print("No models provided to aggregate.")
        sys.exit(1)
        
    print(f"Aggregating {len(args.models)} PyTorch state dicts...")
    
    # 1. Load all state dicts
    state_dicts = []
    try:
        for p in args.models:
            print(f"Loading {p}")
            sd = torch.load(p, map_location='cpu')
            state_dicts.append(sd)
    except Exception as e:
        print(f"Error loading PyTorch models: {e}")
        sys.exit(1)
        
    # 2. Average the weights (FedAvg)
    print("Computing FedAvg...")
    avg_state_dict = average_state_dicts(state_dicts)
    
    if not avg_state_dict:
        print("Error: Averaged state dict is empty.")
        sys.exit(1)

    # 3. Load Base ONNX and convert to PyTorch Graph
    print(f"Loading base architecture from {args.base_model}...")
    try:
        base_onnx = onnx.load(args.base_model)
        pytorch_model = convert(base_onnx)
        pytorch_model.eval()
    except Exception as e:
        print(f"Error mapping ONNX to PyTorch: {e}")
        sys.exit(1)

    # 4. Inject Averaged Weights into ONNX Protobuf directly
    print("Injecting averaged weights into ONNX protobuf...")
    try:
        # Helper to normalize names for matching `onnx2torch` style to ONNX graph style
        def normalize_name(name):
            n = name.replace('/', '.').strip('.')
            if n.startswith('model.'): n = n[6:]
            if n.startswith('model'): n = n[5:] if n.startswith('model.') else n[5:]
            n = n.replace('.Conv.', '.').replace('.conv.', '.')
            n = n.replace('.weight', '').replace('.bias', '')
            return n.strip('.')

        normalized_state = {normalize_name(k): v for k, v in avg_state_dict.items()}
        
        updated_count = 0
        for initializer in base_onnx.graph.initializer:
            init_type = 'weight' if 'weight' in initializer.name.lower() else 'bias'
            norm_init_name = normalize_name(initializer.name)
            
            for state_key, param_val in avg_state_dict.items():
                if normalize_name(state_key) == norm_init_name:
                    state_type = 'weight' if 'weight' in state_key.lower() else 'bias'
                    if init_type != state_type: continue
                    
                    # Convert PyTorch tensor back to numpy bytes
                    param = param_val.detach().cpu().numpy()
                    
                    if list(initializer.dims) == list(param.shape):
                        initializer.raw_data = param.tobytes()
                        updated_count += 1
                        break
                    elif list(initializer.dims) == list(param.shape[::-1]):
                        initializer.raw_data = param.T.copy().tobytes()
                        updated_count += 1
                        break
        
        print(f"Successfully injected {updated_count} averaged parameter sets into ONNX.")
        
        # 5. Save the updated ONNX model
        onnx.save(base_onnx, args.output)
        print(f"Successfully exported aggregated model to {args.output}")
        
    except Exception as e:
        print(f"Error injecting into ONNX: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
