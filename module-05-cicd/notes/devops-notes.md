# DevOps, CI/CD & Monitoring Notes — Module 05

## DevOps culture in one table

| Idea | What it means | Where Chaos Arena does it |
|---|---|---|
| **Automate everything repeatable** | Machines run the boring, error-prone steps | Tests, builds, deploys, rollbacks, healing |
| **Small, frequent changes** | Easier to review, test and undo | One pull request per change; every merge deploys |
| **Fast feedback** | Know within minutes if something broke | PR checks in ~3 min; alarms by email |
| **You build it, you run it** | Developers also own production | I wrote the alarms for my own app |
| **Blameless + measure** | Learn from failures with data | Recovery time recorded for every crash |
| **Infrastructure & config as code** | Servers described in files, in Git | Scripts, Compose files, workflows, alarms, dashboard |

## Git / GitHub workflow I use

```
main ──●─────────────●──────────●──>   (always deployable; every commit on main goes live)
        \           /
 branch  ●───●───●─┘                  edit → push → Pull Request → checks green → merge
```
- **Feature branch + pull request**: changes are reviewed and tested before they reach `main`.
- **Status checks**: `Test`, `Lint`, `Build, integration test & publish` must pass.
- **Tags** (`module-02` … `module-06`) mark milestones; images are tagged by **commit** (`sha-1a2b3c4`) so any version can be traced and redeployed.
- **Dependabot** opens PRs for outdated or vulnerable dependencies; they go through the same checks.

## CI vs CD

| Term | Meaning | My pipeline |
|---|---|---|
| **Continuous Integration** | Every change is automatically built and tested | `test`, `lint`, `build` on every push + PR |
| **Continuous Delivery** | Every passing change is *ready* to release | Images published to GHCR, tagged by commit |
| **Continuous Deployment** | Every passing change *is* released automatically | Deploy agent rolls out `main` within a minute |

## The pipeline, job by job (`.github/workflows/ci-cd.yml`)

| Job | Runs on | Does |
|---|---|---|
| `test` | every push/PR | `npm ci` (exact versions) → `npm test` (26 tests) |
| `lint` | every push/PR | ShellCheck on all scripts; validate both Compose files |
| `build` | after test + lint | Build both images (cached) → **integration test** → push to GHCR (main only) |
| `deploy` | main only | Wait until the live site reports this commit → smoke test |

Good practices in it:
- **Least privilege**: `permissions: contents: read` by default; only `build` may write packages.
- **No long-lived secrets**: `GITHUB_TOKEN` is created per run and expires.
- **Caching**: npm cache + Docker layer cache (`type=gha`) make re-runs fast.
- **Concurrency**: deploys never overlap; a newer PR run cancels the older one.
- **Job summary**: each run writes a results table (image tag, recovery time, live URL).

## Deployment strategies

| Strategy | How | Here? |
|---|---|---|
| **Push** | CI connects to the server (SSH/SSM) and deploys | No: would need keys or open ports |
| **Pull** (GitOps-style) | The server watches the registry and deploys itself | **Yes**, the deploy agent |
| Recreate | Stop old, start new (short gap) | Yes (single small server) |
| Blue/green, canary | Run new next to old, switch traffic gradually | Needs 2+ servers or a load balancer: future work |

**Health-gated rollout + automatic rollback**: the agent only marks a version as deployed when both containers are healthy **and** the app reports the new commit. Otherwise it switches back to the previous version and blocks the bad one from being retried. If the new app keeps crashing (3 restarts), it rolls back early: in testing, a broken release was undone in **9 s**.

## Environment management

| Environment | Where | Data | Config |
|---|---|---|---|
| **Local / dev** | My PC or a Codespace | Docker volume (`STORE=file`) | `compose.yaml` defaults |
| **CI** | GitHub Actions runner | Throw-away volume | Same `compose.yaml`, `CHAOS_COOLDOWN_SEC=5` |
| **Production** | EC2 (Sydney) | DynamoDB + S3 | `compose.aws.yaml` + root-only env file + IAM role |

Same images everywhere; only configuration differs ("build once, run anywhere").

## Monitoring & observability

**Three pillars**: logs (what happened), metrics (how much / how fast), traces (the path of one request; not used here).

| Layer | Tool | Watches |
|---|---|---|
| Container health | Docker `HEALTHCHECK` | Is the app answering? |
| Self-healing | Restart policy + deploy agent | Crashes (Docker) and freezes (agent) |
| Logs | awslogs driver + CloudWatch agent → CloudWatch Logs | App, deploy agent, Nginx |
| Metrics | **Metric filters** turn log lines into numbers | RecoveryTimeMs, ChaosPresses, RoundsFinished, AppErrors, DeploySucceeded, DeployRolledBack, ContainersHealed |
| Alarms → email | CloudWatch alarms → SNS | Slow recovery, errors, rollback, healed container, CPU, EC2 status checks |
| VM self-healing | Alarm actions | EC2 **recover** (hardware issue) / **reboot** (OS stuck) |
| Outside-in | GitHub scheduled workflow | Is the site reachable from the internet? |

Example metric filter: `{ $.msg = "recovered from crash" }` with value `$.recoveryMs`. Every recovery becomes a data point, so I can chart it and alarm on it.

## The self-healing stack (all modules)

| Failure | Detected by | Fixed by | Typical time |
|---|---|---|---|
| App process crashes (CHAOS) | Docker (exit) | Restart policy | ~1 s |
| App frozen but running | Docker health check | Deploy agent restart | < 2 min |
| Bad release | Agent health gate | Automatic rollback | ~10 s – 2 min |
| Web container down | Host Nginx (502) | Static fallback page + restart policy | instant |
| OS hung | EC2 instance status check | Alarm → reboot | minutes |
| AWS hardware failure | EC2 system status check | Alarm → recover | minutes |
| Whole site unreachable | GitHub uptime check | Email to me (human) | ≤ 30 min |
