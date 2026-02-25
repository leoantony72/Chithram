import sys
import onnx
import torch
from onnx2torch import convert

def print_keys(m1_path):
    m1 = onnx.load(m1_path)
    print("--- ONNX Initializer Names ---")
    inits = {i.name: i for i in m1.graph.initializer}
    for k in list(inits.keys())[:15]:
        print(k)

    try:
        pytorch_model = convert(m1)
        state = pytorch_model.state_dict()
        print("\n--- PyTorch State Dict Keys ---")
        for k in list(state.keys())[:15]:
            print(k)
    except Exception as e:
        print(e)

if __name__ == "__main__":
    print_keys(sys.argv[1])
