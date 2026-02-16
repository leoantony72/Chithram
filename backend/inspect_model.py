import onnx
import sys
import os

def inspect_model(name):
    path = f"models/{name}.onnx"
    if not os.path.exists(path):
        print(f"File not found: {path}")
        return

    print(f"Inspecting {name}...")
    try:
        model = onnx.load(path)
        print("Inputs:")
        for input in model.graph.input:
            print(f"  - Name: '{input.name}'")
            print(f"  - Type: {input.type}")
        
        print("Outputs:")
        for output in model.graph.output:
            print(f"  - Name: '{output.name}'")
            
    except Exception as e:
        print(f"  - Error: {e}")

if __name__ == "__main__":
    inspect_model("face-recognition")
