package controllers

import (
	"chithram/database"
	"chithram/models"
	"fmt"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

func GetDashboard(c *gin.Context) {
	var metrics []models.ModelMetric
	database.DB.Order("created_at ASC").Find(&metrics)

	// Prepare data for the chart
	var labelList []string
	var accList []string
	var lossList []string

	for _, m := range metrics {
		labelList = append(labelList, fmt.Sprintf("'%s'", m.CreatedAt.Format("01-02 15:04")))
		accList = append(accList, fmt.Sprintf("%.4f", m.Accuracy))
		lossList = append(lossList, fmt.Sprintf("%.4f", m.Loss))
	}

	labelStr := "[" + strings.Join(labelList, ",") + "]"
	accStr := "[" + strings.Join(accList, ",") + "]"
	lossStr := "[" + strings.Join(lossList, ",") + "]"

	html := fmt.Sprintf(`
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AI Training Dashboard</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap" rel="stylesheet">
    <style>
        body {
            font-family: 'Inter', sans-serif;
            background: #0f172a;
            color: #f8fafc;
            margin: 0;
            padding: 40px;
            display: flex;
            flex-direction: column;
            align-items: center;
        }
        .container {
            max-width: 1000px;
            width: 100%%;
            background: #1e293b;
            padding: 30px;
            border-radius: 20px;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
            border: 1px solid #334155;
        }
        h1 {
            font-size: 2.5rem;
            margin-bottom: 30px;
            background: linear-gradient(to right, #38bdf8, #818cf8);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            font-weight: 600;
        }
        .stats {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 20px;
            margin-bottom: 30px;
        }
        .card {
            background: #0f172a;
            padding: 20px;
            border-radius: 15px;
            border: 1px solid #334155;
            text-align: center;
        }
        .card h2 {
            font-size: 0.875rem;
            color: #94a3b8;
            margin: 0 0 10px 0;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }
        .card p {
            font-size: 2rem;
            margin: 0;
            font-weight: 600;
            color: #38bdf8;
        }
        canvas {
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <h1>Federated Learning Dashboard</h1>
    <div class="container">
        <div class="stats">
            <div class="card">
                <h2>Total Aggregations</h2>
                <p>%d</p>
            </div>
            <div class="card">
                <h2>Current Accuracy</h2>
                <p>%.2f%%</p>
            </div>
        </div>
        <canvas id="accuracyChart" height="150"></canvas>
    </div>

    <script>
        const ctx = document.getElementById('accuracyChart').getContext('2d');
        new Chart(ctx, {
            type: 'line',
            data: {
                labels: %s,
                datasets: [{
                    label: 'Model Accuracy',
                    data: %s,
                    borderColor: '#38bdf8',
                    backgroundColor: 'rgba(56, 189, 248, 0.1)',
                    borderWidth: 3,
                    tension: 0.4,
                    fill: true,
                    pointBackgroundColor: '#38bdf8',
                    pointRadius: 5
                }, {
                    label: 'Model Loss',
                    data: %s,
                    borderColor: '#f472b6',
                    backgroundColor: 'rgba(244, 114, 182, 0.1)',
                    borderWidth: 3,
                    tension: 0.4,
                    fill: true,
                    pointBackgroundColor: '#f472b6',
                    pointRadius: 5,
                    hidden: true
                }]
            },
            options: {
                responsive: true,
                plugins: {
                    legend: {
                        labels: { color: '#f8fafc' }
                    }
                },
                scales: {
                    y: {
                        grid: { color: '#334155' },
                        ticks: { color: '#94a3b8' },
                        min: 0,
                        max: 1
                    },
                    x: {
                        grid: { color: '#334155' },
                        ticks: { color: '#94a3b8' }
                    }
                }
            }
        });
    </script>
</body>
</html>
`, len(metrics), getLatestAcc(metrics)*100, labelStr, accStr, lossStr)

	c.Data(http.StatusOK, "text/html; charset=utf-8", []byte(html))
}

func getLatestAcc(m []models.ModelMetric) float64 {
	if len(m) == 0 {
		return 0
	}
	return m[len(m)-1].Accuracy
}
