# Cloud Services Notes — Module 03

## The service families, and what I used from each

| Family | What it gives you | AWS service I used | Other examples |
|---|---|---|---|
| **Compute** | CPUs and memory to run code | **EC2** (a virtual machine I manage) | Lambda (functions), ECS/Fargate (containers), Lightsail |
| **Object storage** | Whole files ("objects") in buckets, very durable and cheap | **S3** | Azure Blob Storage, Google Cloud Storage |
| **Managed database** | A database the provider patches, backs up and scales | **DynamoDB** (NoSQL key-value) | RDS/Aurora (SQL), DocumentDB, ElastiCache |
| **Virtual networking** | Private networks, firewalls, routing | **VPC**, security group, Elastic IP | Load balancers, NAT gateways, Route 53 (DNS) |
| **Identity & access** | Who may do what | **IAM** role + policy | IAM users, groups, Identity Center |
| **Monitoring** | Logs, metrics, alarms | **CloudWatch Logs** | CloudWatch Metrics/Alarms, X-Ray, CloudTrail |

"Managed" means AWS runs the servers for that service. I never patch, back up or scale DynamoDB or S3; I only use them through an API.

## Storage: which one for what?

| | **EBS** (the server's disk) | **S3** | **DynamoDB** |
|---|---|---|---|
| Stores | Files on one VM | Objects (whole files) | Items (small records) |
| Access | Only from that VM | HTTPS API from anywhere allowed | HTTPS API from anywhere allowed |
| Survives the VM being deleted? | No (by default) | Yes | Yes |
| Good for | OS, app code, logs | Backups, images, reports | Live app data that changes often |
| In Chaos Arena | Code + `app.log` | Incident reports, score backup | Rope position, scores, incidents |

That's why the game survives a crash: its state is **not** kept on the server that crashes.

## DynamoDB in five lines
- A **table** holds **items**; each item is found by its **primary key**.
- My key has two parts: **partition key** `pk` (the category) + **sort key** `sk` (order inside the category).
- `GetItem` = fetch one item by its full key. `Query` = fetch items with the same `pk`, sorted by `sk`. Both are fast and cheap. (`Scan` reads the whole table: avoid it.)
- **Capacity**: I chose *provisioned* 5 read + 5 write units, inside the always-free 25/25. *On-demand* bills per request instead.
- **Single-table design**: different kinds of items (`STATE`, `INCIDENT`, `ROUND`) share one table, told apart by `pk`.

## IAM: the most important idea of this module

| Term | Meaning |
|---|---|
| **Principal** | Who is asking: a user, or a service such as an EC2 instance |
| **Policy** | A JSON document listing allowed (or denied) **actions** on **resources** |
| **Role** | An identity with policies that is *assumed* temporarily; it has no password or permanent keys |
| **Trust policy** | Says *who may assume* the role (mine: only `ec2.amazonaws.com`) |
| **Instance profile** | The wrapper that attaches a role to an EC2 instance |
| **Least privilege** | Grant only what is needed, on only the resources needed |

How my server gets credentials **without any access keys**:
```
Node.js AWS SDK ──asks──> Instance Metadata Service (169.254.169.254, IMDSv2, token required)
                <──────── temporary credentials for chaos-arena-ec2-role (auto-rotated every few hours)
```
My policy allows exactly: 4 DynamoDB actions on **one table**, 3 S3 actions on **one bucket**, and writing to log groups under `/chaos-arena/`. If the server were hacked, the attacker could not create servers, read other buckets, or touch IAM.

**Never** put `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in code or on a server when a role can be used instead. Leaked keys on GitHub are found by bots within minutes.

## Environment variables & secrets
- **Config belongs in the environment, not in code** ("12-factor app"). The same code runs on my laptop (`STORE=file`) and on AWS (`STORE=dynamo`).
- `app/.env.example` documents every setting with fake values. The real file is `/etc/chaos-arena/chaos-arena.env`.
- **A secret** is any value that grants access (here: `ADMIN_TOKEN`). Rules I followed:
  1. Generated on the server (`openssl rand -hex 24`), never typed or emailed.
  2. Stored in a `root`-only file (`chmod 600`); systemd reads it and passes it to the app.
  3. Listed in `.gitignore` patterns (`.env`, `*.pem`), so it can't be committed by accident.
  4. Never printed: the app logs `***set***` instead of the value.
  5. Compared with `crypto.timingSafeEqual` so it can't be guessed by timing responses.
- Next level (not needed yet): **AWS Systems Manager Parameter Store** or **Secrets Manager**, which store secrets encrypted in AWS and can rotate them.

## Application logging
- The app writes **one JSON object per line** to stdout: `{"time":…,"level":"info","msg":"round finished","winner":"blue"}`.
- systemd appends stdout to `/srv/chaos-arena/logs/app.log`; **logrotate** keeps 7 compressed days so the disk never fills.
- The **CloudWatch agent** ships the file to the log group `/chaos-arena/app` (kept 14 days).
- Why ship logs off the server? If the server dies, the logs that explain *why* are still there.
- Log **levels**: `info` (normal events), `warn` (unusual but handled, e.g. CHAOS pressed), `error` (something failed).
- Useful CloudWatch filter patterns:
  - `{ $.level = "error" }`: all errors
  - `{ $.msg = "recovered from crash" }`: every recovery, with `recoveryMs`
  - `{ $.msg = "round finished" && $.winner = "red" }`

## Resource quotas (limits that protect a small server and a free account)

| Layer | Limit | Why |
|---|---|---|
| systemd | `MemoryMax=300M`, `CPUQuota=60%`, `TasksMax=100` | A bug or attack can't starve SSH/Nginx on a 1 GB server |
| App | 16 clicks/s per player, 200/s per IP, 1 KB request bodies, 8 clicks per request | Fair play; no flooding the database |
| App | CHAOS cooldown 60 s (saved in DynamoDB, so it survives the crash) | The game can't be kept down forever |
| Nginx | `limit_req` 100 requests/s per IP → HTTP 429 | Stops floods before they reach Node.js |
| DynamoDB | 5 read / 5 write capacity units; state saved at most every 3 s | Stays inside the free allowance |
| CloudWatch | 14-day log retention | Storage can't grow forever |
| S3 | Incident reports expire after 90 days | Same |
| AWS account | **Service quotas** (e.g. max vCPUs per region), plus my zero-spend budget | AWS-side safety limits |

## Networking in this module
- The Node.js app listens on **127.0.0.1:3000**: reachable only from the server itself.
- **Nginx is a reverse proxy**: it accepts HTTPS from the internet and forwards `/api/` to the app. Benefits: one place for TLS, security headers and rate limits; the app never faces the internet directly; the web page still loads when the app is down.
- No firewall changes were needed: port 3000 is not in the security group or UFW, on purpose.
- Calls to DynamoDB/S3/CloudWatch go **out** over HTTPS to AWS's regional endpoints; outbound traffic is allowed by default.

## Health checks: two levels
| URL | Answered by | Tells me |
|---|---|---|
| `/health` | Nginx | The web server is up |
| `/api/health` | Node.js | The app is up |
| `/api/status` | Node.js → AWS | The app can reach its database and storage |

## Words I learned
- **Reverse proxy**: a server that receives requests on behalf of another server.
- **Idempotent**: safe to run twice (all my scripts check "already exists?" first).
- **Graceful shutdown**: on `SIGTERM` the app saves the game before exiting. The CHAOS crash deliberately is *not* graceful.
- **Self-healing**: the system detects a failure and repairs it without a human.
- **Recovery time (MTTR)**: how long from failure to working again. Mine is about 2–3 s, mostly systemd's `RestartSec=2`.
