import torch
import torch.nn.functional as F

class NTXentLoss(torch.nn.Module):
    def __init__(self, temperature=0.5):
        super(NTXentLoss, self).__init__()
        self.temperature = temperature
        self.cosine_similarity = torch.nn.CosineSimilarity(dim=-1)

    def forward(self, z_i, z_j):
        batch_size = z_i.shape[0]
        # Check for batch_size = 1 which breaks contrastive learning mathematically
        if batch_size == 1:
            print("WARNING: Batch size 1 detected. Contrastive loss requires at least 2 samples.")
            # We can't do contrastive on a batch of 1. At best, we can just return a dummy non-zero 
            # gradient to keep the loop alive, but the math is meaningless.
            return torch.tensor(0.0, requires_grad=True)

        z = torch.cat((z_i, z_j), dim=0)
        
        sim = self.cosine_similarity(z.unsqueeze(1), z.unsqueeze(0)) / self.temperature
        
        sim_i_j = torch.diag(sim, batch_size)
        sim_j_i = torch.diag(sim, -batch_size)
        
        positives = torch.cat((sim_i_j, sim_j_i), dim=0)
        
        mask = (~torch.eye(2 * batch_size, 2 * batch_size, dtype=torch.bool)).float()
        
        nominator = torch.exp(positives)
        denominator = mask * torch.exp(sim)
        
        loss = -torch.log(nominator / (torch.sum(denominator, dim=1) + 1e-8))
        return torch.mean(loss)
        
print("Testing batch size 2")
z1 = torch.rand(2, 512, requires_grad=True)
z2 = torch.rand(2, 512, requires_grad=True)
criterion = NTXentLoss()
loss = criterion(z1, z2)
print("Loss BN2:", loss.item())

print("Testing batch size 1")
z1_b1 = torch.rand(1, 512, requires_grad=True)
z2_b1 = torch.rand(1, 512, requires_grad=True)
loss_b1 = criterion(z1_b1, z2_b1)
print("Loss BN1:", loss_b1.item())
