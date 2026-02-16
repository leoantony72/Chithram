import onnx
import sys
import os
import onnx.numpy_helper

def clean_split_node(model):
    """
    Downgrade Split node from Opset 11+ (split as input) to Opset < 11 (split as attribute).
    """
    print("Checking for Split node compatibility...")
    graph = model.graph
    
    nodes_to_remove = []
    
    for node in graph.node:
        if node.op_type == "Split":
            # If Split has 2 inputs, the second input represents the split sizes.
            if len(node.input) == 2:
                split_tensor_name = node.input[1]
                
                # Find the initializer or constant node providing the split sizes
                split_val = None
                
                # Check initializers
                for init in graph.initializer:
                    if init.name == split_tensor_name:
                        split_val = onnx.numpy_helper.to_array(init).tolist()
                        break
                
                # If not found in initializers, check Constant nodes
                if split_val is None:
                    for c_node in graph.node:
                        if c_node.output[0] == split_tensor_name and c_node.op_type == "Constant":
                            split_val = onnx.numpy_helper.to_array(c_node.attribute[0].t).tolist()
                            nodes_to_remove.append(c_node)
                            break
                            
                if split_val:
                    print(f"  - Fixing Split node {node.name}: converting input {split_tensor_name} to attribute 'split'={split_val}")
                    new_attr = onnx.helper.make_attribute("split", split_val)
                    node.attribute.append(new_attr)
                    del node.input[1] # Remove input 1
                else:
                    print(f"  - WARNING: Could not find value for Split input {split_tensor_name}")

    # Remove the constant nodes that are no longer needed
    for node in nodes_to_remove:
        if node in graph.node:
            graph.node.remove(node)
            
    return model

def clean_resize_node(model):
    """
    Downgrade Resize node inputs and attributes for Opset 10 compatibility.
    Opset 10 Inputs: X, scales (2 inputs)
    Opset 11+ Inputs: X, roi, scales, sizes (3 or 4 inputs)
    
    Opset 10 Attributes: mode (string) - 'nearest', 'linear', 'bilinear' (treated as linear)
    Opset 11+ Attributes: coordinate_transformation_mode, cubic_coeff_a, exclude_outside, extrapolation_value, mode, nearest_mode
    """
    print("Checking for Resize node compatibility...")
    graph = model.graph
    
    for node in graph.node:
        if node.op_type == "Resize":
            # 1. Fix Inputs: Remove empty 'roi' input if present
            # We want [X, scales] (2 inputs)
            if len(node.input) > 2:
                # Opset 11 usually has [X, roi, scales, sizes]. roi is empty string often.
                # If input[1] is empty string, it's definitely roi.
                if node.input[1] == "":
                    print(f"  - Fixing Resize node {node.name}: removing empty 'roi' input.")
                    node.input.pop(1)
                
                # After popping, we might have [X, scales, sizes].
                # Opset 10 Resize takes [X, scales].
                # If we have 3 inputs, likely [X, scales, sizes].
                # We usually just want scales.
                if len(node.input) > 2:
                    # Truncate to 2 inputs
                    print(f"  - Fixing Resize node {node.name}: truncating inputs to length 2 (X, scales).")
                    del node.input[2:]

            # 2. Fix Attributes: Remove unsupported attributes for Opset 10
            # Allowed: mode
            allowed_attrs = ["mode"]
            attrs_to_remove = []
            
            for attr in node.attribute:
                if attr.name not in allowed_attrs:
                    attrs_to_remove.append(attr)
                elif attr.name == "mode":
                    # Check mode value. Opset 10 supports 'nearest', 'linear'.
                    # 'cubic' is not supported in Opset 10.
                    mode_val = onnx.helper.get_attribute_value(attr).decode('utf-8')
                    if mode_val == "cubic":
                        print(f"  - Fixing Resize node {node.name}: changing mode 'cubic' to 'linear'.")
                        attr.s = b"linear"

            for attr in attrs_to_remove:
                print(f"  - Fixing Resize node {node.name}: removing attribute '{attr.name}'.")
                node.attribute.remove(attr)

    return model

def fix_model_compatibility(name):
    path = f"models/{name}.onnx"
    if not os.path.exists(path):
        print(f"File not found: {path} - Skipping")
        return

    print(f"\nProcessing {name} for compatibility...")
    try:
        model = onnx.load(path)
        
        # 1. Fix Split nodes (Input -> Attribute)
        model = clean_split_node(model)
        
        # 2. Fix Resize nodes
        model = clean_resize_node(model)
        
        # 3. Force Opset 10
        old_opset = model.opset_import[0].version
        model.opset_import[0].version = 10
        print(f"  - Changed Opset version from {old_opset} to 10")
        
        # 4. Force IR Version 6
        model.ir_version = 6
        print("  - Set IR version to 6")
        
        onnx.save(model, path)
        print(f"  - SUCCESS: Saved patched model to {path}")

    except Exception as e:
        print(f"  - Error: {e}")

if __name__ == "__main__":
    fix_model_compatibility("face-detection")
    fix_model_compatibility("face-recognition")
