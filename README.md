# Chaos Arena

**A multiplayer tug-of-war you're *allowed* to break.**
Pick Team Red or Team Blue and click to pull the rope, or smash the **CHAOS** button to crash the server on purpose. Then watch it heal itself while a live panel shows uptime, crash count and recovery time.

Chaos Arena is my project for the **Codomax Digital Solutions Cloud Computing & DevOps virtual internship**. Each module adds a new layer of cloud and DevOps engineering to the same app, so it gets more resilient with every module.

🌐 **Live:** `https://<your-subdomain>.duckdns.org` *(teaser page from Module 02; the game arrives in Module 03)*

## Roadmap

| Module | Days | What it adds | Self-healing level | Status |
|---|---|---|---|---|
| [02 · Linux, Networking & Cloud Infrastructure](module-02-linux-networking/) | 6–10 | Hardened Ubuntu EC2 server, firewall, DNS, Nginx, HTTPS | — | 🚧 In progress |
| 03 · Cloud Services & Web App Deployment | 11–15 | Node.js game + DynamoDB + S3 + IAM role + CloudWatch logs | systemd restarts the app | ⏳ |
| 04 · Docker & Containerization | 16–20 | Dockerfile, Docker Compose, Nginx reverse proxy | Docker restart policy + health checks | ⏳ |
| 05 · DevOps, CI/CD & Monitoring | 21–25 | GitHub Actions test + deploy, CloudWatch alarms, recovery-time charts | Pipeline + alarms | ⏳ |
| 06 · Capstone | 26–30 | Architecture diagram, final docs, demo | Full stack | ⏳ |

Each finished module is saved as a **git tag**, so you can see the project exactly as it was at that point:
`https://github.com/l3n8n-ocd/chaos-arena/tree/module-02`

## Tech stack
**AWS** (EC2, Elastic IP, Security Groups, DynamoDB, S3, IAM, CloudWatch) · **Ubuntu 24.04** · **Nginx** · **Let's Encrypt** · **DuckDNS** · **Node.js + Express** · **Docker / Compose** · **GitHub Actions**

## Repository layout
```
chaos-arena/
├── README.md                      ← you are here
├── module-02-linux-networking/    ← server setup scripts, configs, notes, evidence
├── docs/screenshots/              ← screenshots for each module
└── (app/, docker/, .github/ ... added in later modules)
```

## Author
**Lenon Adriano** · B.S. Information Technology
Cloud Computing & DevOps Intern @ Codomax Digital Solutions
