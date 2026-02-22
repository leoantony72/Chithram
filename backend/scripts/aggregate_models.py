import argparse
import onnx
import numpy as np
import os
import sys

def load_model(path):
    print(f"Loading model: {path}")
    return onnx.load(path)

def extract_weights(model):
    """
    Extracts weights (initializers) from an ONNX model into a dictionary of numpy arrays.
    """
    weights = {}
    for tensor in model.graph.initializer:
        # Convert raw data to numpy array based on data type
        # For simplicity, we handle float32 (most common for weights)
        if tensor.data_type == onnx.TensorProto.FLOAT:
             weights[tensor.name] = np.frombuffer(tensor.raw_data, dtype=np.float32).reshape(tensor.dims)
        # Add handling for other types if needed (INT64, DOUBLE, etc.)
        elif tensor.data_type == onnx.TensorProto.INT64:
             weights[tensor.name] = np.frombuffer(tensor.raw_data, dtype=np.int64).reshape(tensor.dims)
        else:
             # Fallback or skip
             pass
    return weights

def average_weights(weight_list):
    """
    Computes the element-wise average of weights from multiple models.
    """
    avg_weights = {}
    if not weight_list:
        return avg_weights
    
    # Initialize with first model's weights
    first_weights = weight_list[0]
    keys = first_weights.keys()
    
    num_models = len(weight_list)
    
    for key in keys:
        # Sum up weights for this key across all models
        total = np.zeros_as_array(first_weights[key]) # ensure same shape
        count = 0 
        
        for w in weight_list:
            if key in w:
               total = total + w[key]
               count += 1
            else:
               print(f"Warning: Weight {key} missing in one of the models")
        
        if count > 0:
            avg_weights[key] = total / count
            
    return avg_weights

def update_model_weights(base_model, new_weights):
    """
    Updates the base model's initializers with new averaged weights.
    """
    for tensor in base_model.graph.initializer:
        if tensor.name in new_weights:
            # Update raw_data
            new_data = new_weights[tensor.name].tobytes()
            tensor.raw_data = new_data
            
    return base_model

def main():
    parser = argparse.ArgumentParser(description='Aggregate ONNX models via FedAvg')
    parser.add_argument('models', nargs='+', help='List of ONNX model paths to aggregate')
    parser.add_argument('--output', required=True, help='Path to save the aggregated model')
    
    args = parser.parse_args()
    
    if not args.models:
        print("No models provided to aggregate.")
        sys.exit(1)
        
    print(f"Aggregating {len(args.models)} models...")
    
    # Load all models
    models = []
    try:
        for p in args.models:
            models.append(load_model(p))
    except Exception as e:
        print(f"Error loading models: {e}")
        sys.exit(1)
        
    # Extract weights
    # We assume models have identical architecture and initializer names
    # In a real FL system, we'd do stricter validation
    
    all_weights = []
    for m in models:
        # For now, let's use a simpler approach using onnx helper for numpy conversion if available,
        # but since we want to be dependency-lite, we'll manually parse raw_data for float32
        
        # NOTE: The manual parsing in extract_weights is fragile if endianness varies or compression is used.
        # A robust solution uses onnx.numpy_helper
        from onnx import numpy_helper
        
        weights = {}
        for tensor in m.graph.initializer:
            weights[tensor.name] = numpy_helper.to_array(tensor)
        all_weights.append(weights)
        
    # Average weights
    # We averaging initializers (parameters).
    # Note: Logic for averaging other parameters (like Batch Normalization running stats) 
    # should be handled carefully. FedAvg usually just averages them.
    
    keys = all_weights[0].keys()
    avg_weights = {}
    n = len(all_weights)
    
    for key in keys:
        try:
             # Sum
             total = all_weights[0][key].astype(np.float64) # Use float64 for accumulation precision
             for i in range(1, n):
                 total += all_weights[i][key]
             
             # Average
             avg_weights[key] = (total / n).astype(all_weights[0][key].dtype)
        except Exception as e:
             print(f"Error averaging weight {key}: {e}")
             
    # Create new model based on the first one
    base_model = models[0]
    
    # Update initializers
    from onnx import numpy_helper
    
    # We clear the old initializers and add new ones to avoid duplication issues if we just modified them,
    # but modifying in place is often safer for preserving metadata.
    # However, onnx.numpy_helper.from_array creates a new TensorProto.
    # We need to replace the existing ones.
    
    new_initializers = []
    for tensor in base_model.graph.initializer:
        if tensor.name in avg_weights:
            new_tensor = numpy_helper.from_array(avg_weights[tensor.name], name=tensor.name)
            new_initializers.append(new_tensor)
        else:
            new_initializers.append(tensor) # Keep unchanged if not averaged
            
    # Clear and replace
    del base_model.graph.initializer[:]
    base_model.graph.initializer.extend(new_initializers)
    
    # Save
    onnx.save(base_model, args.output)
    print(f"Aggregated model saved to {args.output}")

if __name__ == "__main__":
    main()
