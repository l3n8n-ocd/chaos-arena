# Chaos Arena

**A multiplayer tug-of-war you're *allowed* to break.**
Pick Team Red or Team Blue and click to pull the rope, or smash the **CHAOS** button to crash the server on purpose. Then watch it heal itself while a live panel shows uptime, crash count and recovery time.

🌐 **Play it:** [https://chaos-arena.duckdns.org](https://chaos-arena.duckdns.org)

Chaos Arena is my project for the **Codomax Digital Solutions Cloud Computing & DevOps virtual internship**. Each module adds a new layer of cloud and DevOps engineering to the same app, so it gets more resilient with every module.

## Architecture (after Module 03)

```mermaid
flowchart LR
    P["Players"] -- "HTTPS" --> N
    subgraph AWS["AWS"]
        subgraph EC2["EC2 - Ubuntu 24.04 (UFW, fail2ban, key-only SSH)"]
            N["Nginx<br/>TLS, static page, reverse proxy"] --> A["Node.js game<br/>auto-restarted by systemd"]
        end
        A --> D[("DynamoDB<br/>game state + incidents")]
        A --> S[("S3<br/>backups")]
        A -. "logs" .-> CW["CloudWatch Logs"]
        R["IAM role<br/>least privilege, no access keys"] -.-> A
    end
```

**The trick that makes it survive a crash:** the game's state lives in DynamoDB, not on the server. When the process dies, systemd restarts it, it reloads the state, and it measures how long the recovery took.

## Roadmap

| Module | Days | What it adds | Self-healing level | Status |
|---|---|---|---|---|
| [02 · Linux, Networking & Cloud Infrastructure](module-02-linux-networking/) | 6–10 | Hardened Ubuntu EC2 server, firewall, DNS, Nginx, HTTPS | — | ✅ Done |
| [03 · Cloud Services & Web App Deployment](module-03-cloud-services/) | 11–15 | Node.js game + DynamoDB + S3 + IAM role + CloudWatch logs | systemd restarts the app | 🚧 In progress |
| 04 · Docker & Containerization | 16–20 | Dockerfile, Docker Compose, Nginx reverse proxy | Docker restart policy + health checks | ⏳ |
| 05 · DevOps, CI/CD & Monitoring | 21–25 | GitHub Actions test + deploy, CloudWatch alarms, recovery-time charts | Pipeline + alarms | ⏳ |
| 06 · Capstone | 26–30 | Architecture diagram, final docs, demo | Full stack | ⏳ |

Each finished module is saved as a **git tag**, so you can see the project exactly as it was at that point, e.g.
`https://github.com/l3n8n-ocd/chaos-arena/tree/module-02`

## Tech stack
**AWS** (EC2, Elastic IP, Security Groups, DynamoDB, S3, IAM, CloudWatch) · **Ubuntu 24.04** · **Nginx** · **Let's Encrypt** · **DuckDNS** · **Node.js + Express** · **systemd** · **Docker / Compose** *(Module 04)* · **GitHub Actions** *(Module 05)*

## Repository layout
```
chaos-arena/
├── README.md                      ← you are here
├── app/                           ← the game (Node.js API, web page, tests)
├── infra/aws/                     ← scripts + policies that create the AWS resources
├── module-02-linux-networking/    ← server setup: scripts, configs, notes, evidence
├── module-03-cloud-services/      ← app deployment: scripts, systemd, Nginx, notes, evidence
└── docs/screenshots/              ← screenshots for each module
```

## Run it locally
Needs only [Node.js](https://nodejs.org) 20 or newer. No AWS account required: data is kept in a local file.
```bash
cd app
npm install
npm test            # automated tests
npm run dev:heal    # open http://localhost:3000 and press CHAOS
```

## Author
**Lenon Adriano** · B.S. Information Technology
Cloud Computing & DevOps Intern @ Codomax Digital Solutions
