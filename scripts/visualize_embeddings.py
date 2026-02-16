
import json
import os
import sys
import numpy as np
import matplotlib.pyplot as plt
from sklearn.manifold import TSNE
from sklearn.decomposition import PCA

def main():
    # 1. Load Data
    json_path = 'face_vectors_dump.json'
    if len(sys.argv) > 1:
        json_path = sys.argv[1]

    if not os.path.exists(json_path):
        print(f"Error: File '{json_path}' not found.")
        print("Please export the data from the app and place 'face_vectors_dump.json' in this directory.")
        return

    with open(json_path, 'r') as f:
        data = json.load(f)

    if not data:
        print("No data found in JSON.")
        return

    print(f"Loaded {len(data)} face records.")

    # 2. Extract Vectors and Labels
    vectors = []
    cluster_ids = []
    paths = []
    ids = []

    for item in data:
        vectors.append(item['vector']) # Should be list of 128 floats
        # Handle null cluster_id (unclustered noise)
        cid = item.get('cluster_id')
        if cid is None:
            cid = -1 
        cluster_ids.append(cid)
        paths.append(item.get('path', ''))
        ids.append(item.get('id'))

    X = np.array(vectors)
    y = np.array(cluster_ids)

    print(f"Data shape: {X.shape}")
    
    if X.shape[1] not in [128, 512]:
        print(f"ERROR: Expected 128 or 512 dimensions, but got {X.shape[1]}.")
        print("This indicates garbage data (file read error).")
        print("Please:")
        print("1. Rebuild and Run the App (to apply the latest fixes).")
        print("2. Tap 'Export Vectors JSON' again.")
        print("3. Copy the NEW 'face_vectors_dump.json' to this folder.")
        return

    # 3. Reduce Dimensions
    # Using t-SNE for 2D visualization
    print("Running t-SNE...")
    # Perplexity should be considerably smaller than number of points
    perp = min(30, len(data) - 1)
    if perp < 5: perp = 5
    
    tsne = TSNE(n_components=2, perplexity=perp, random_state=42, init='pca', learning_rate='auto')
    X_2d = tsne.fit_transform(X)

    # 4. Plot
    plt.figure(figsize=(12, 10))
    
    # Get unique clusters for coloring
    unique_clusters = np.unique(y)
    colors = plt.cm.rainbow(np.linspace(0, 1, len(unique_clusters)))
    
    for cluster_id, color in zip(unique_clusters, colors):
        mask = (y == cluster_id)
        label = f"Cluster {cluster_id}" if cluster_id != -1 else "Unclustered"
        if cluster_id == -1:
            color = 'black' # Noise/Unclustered
            
        plt.scatter(X_2d[mask, 0], X_2d[mask, 1], c=[color], label=label, alpha=0.7, edgecolors='w')

    # Add annotations (optional - can get crowded)
    # Using filenames as labels if fewer than 50 points
    if len(data) < 50:
        for i, (x_coord, y_coord) in enumerate(X_2d):
            fname = os.path.basename(paths[i])
            plt.annotate(fname, (x_coord, y_coord), fontsize=8, alpha=0.8)

    plt.title('Face Embeddings Visualization (t-SNE)')
    plt.xlabel('Dimension 1')
    plt.ylabel('Dimension 2')
    plt.legend(bbox_to_anchor=(1.05, 1), loc='upper left')
    plt.tight_layout()
    
    output_img = 'face_clusters_plot.png'
    plt.savefig(output_img)
    print(f"Plot saved to {output_img}")
    plt.show()

if __name__ == "__main__":
    main()
