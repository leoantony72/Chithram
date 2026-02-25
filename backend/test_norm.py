import sys
import onnx
import torch
import numpy as np

def test_shapes(m1_path):
    m1 = onnx.load(m1_path)
    from onnx2torch import convert
    pytorch_model = convert(m1)
    state = pytorch_model.state_dict()
    
    inits = {i.name: i for i in m1.graph.initializer}
    
    def normalize_name(name):
        n = name.replace('/', '.').strip('.')
        if n.startswith('model.'): n = n[6:]
        if n.startswith('model'): n = n[5:] if n.startswith('model.') else n[5:]
        n = n.replace('.Conv.', '.').replace('.conv.', '.')
        n = n.replace('.weight', '').replace('.bias', '')
        return n.strip('.')

    for init_name, init in list(inits.items())[:10]:
        norm_i = normalize_name(init_name)
        i_type = 'weight' if 'weight' in init_name.lower() else 'bias'
        for k, v in state.items():
            if normalize_name(k) == norm_i:
                k_type = 'weight' if 'weight' in k.lower() else 'bias'
                if i_type == k_type:
                    p_shape = list(v.shape)
                    i_shape = list(init.dims)
                    print(f"Match found: {init_name} <-> {k}")
                    print(f"  ONNX Shape: {i_shape}")
                    print(f"  PT Shape:   {p_shape}")
                    if i_shape == p_shape or i_shape == p_shape[::-1]:
                        print("  MATCH!")
                    else:
                        print("  SHAPE MISMATCH")
                    break

if __name__ == "__main__":
    test_shapes(sys.argv[1])

