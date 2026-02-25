import sys
import onnx
import torch

def compare_names(m1_path, pth_path):
    m1 = onnx.load(m1_path)
    state = torch.load(pth_path, map_location='cpu')
    
    print("--- ONNX Initializer Names ---")
    for i in list(m1.graph.initializer)[:10]:
        print(i.name)
        
    print("--- PyTorch State Dict Keys ---")
    for k in list(state.keys())[:10]:
        print(k)

if __name__ == "__main__":
    compare_names(sys.argv[1], sys.argv[2])

