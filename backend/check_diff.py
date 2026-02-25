import onnx
import numpy as np

def check_diff(m1_path, m2_path):
    m1 = onnx.load(m1_path)
    m2 = onnx.load(m2_path)
    
    m1_inits = {i.name: i for i in m1.graph.initializer}
    m2_inits = {i.name: i for i in m2.graph.initializer}
    
    diff_count = 0
    for name, i1 in m1_inits.items():
        if name in m2_inits:
            i2 = m2_inits[name]
            try:
                arr1 = np.frombuffer(i1.raw_data, dtype=np.float32)
                arr2 = np.frombuffer(i2.raw_data, dtype=np.float32)
                if not np.array_equal(arr1, arr2):
                    diff_count += 1
            except:
                pass
    print(f"Total diffs: {diff_count}")

check_diff("models/face-detection.onnx", "models/face-detection_old_1772028187.onnx")
