#!/usr/bin/env python3
"""Builds docs/architecture.svg for Chaos Arena with embedded icons.

Icons: AWS Architecture Icons (via the MIT-licensed `aws-icons` npm package)
and Simple Icons (CC0). Every icon is inlined, so the SVG has no external refs.
Usage: make_diagram.py <node_modules dir> <output.svg>
"""
import json
import re
import sys

NM, OUT = sys.argv[1], sys.argv[2]
AWS = f"{NM}/aws-icons/icons"
SI = f"{NM}/simple-icons"

si_data = {i["slug"]: i for i in json.load(open(f"{SI}/data/simple-icons.json"))}

def load(path):
    raw = open(path).read()
    raw = re.sub(r"<\?xml[^>]*>", "", raw)
    raw = re.sub(r"<title>.*?</title>", "", raw, flags=re.S)
    vb = re.search(r'viewBox="([^"]+)"', raw).group(1)
    inner = re.search(r"<svg[^>]*>(.*)</svg>", raw, re.S).group(1)
    return vb, inner

out = []
def add(s): out.append(s)

# --------------------------------------------------------------------------- icons
def aws_icon(rel, x, y, s):
    """AWS service/group icon (has its own coloured square), rounded corners."""
    vb, inner = load(f"{AWS}/{rel}.svg")
    add(f'<g clip-path="url(#round)"><svg x="{x}" y="{y}" width="{s}" height="{s}" viewBox="{vb}">{inner}</svg></g>')

def tile(x, y, s, r=None):
    r = r if r is not None else round(s * 0.2)
    add(f'<rect x="{x}" y="{y}" width="{s}" height="{s}" rx="{r}" fill="#ffffff"/>')

def res_icon(rel, x, y, s):
    """AWS resource glyph (no background) on a white tile."""
    tile(x, y, s)
    vb, inner = load(f"{AWS}/resource/{rel}.svg")
    p = s * 0.12
    add(f'<svg x="{x+p:.1f}" y="{y+p:.1f}" width="{s-2*p:.1f}" height="{s-2*p:.1f}" viewBox="{vb}">{inner}</svg>')

def si_icon(slug, x, y, s, pad=0.2):
    """Simple Icons brand logo in its brand colour on a white tile."""
    tile(x, y, s)
    vb, inner = load(f"{SI}/icons/{slug}.svg")
    color = "#" + si_data[slug]["hex"]
    inner = inner.replace("<path ", f'<path fill="{color}" ')
    p = s * pad
    add(f'<svg x="{x+p:.1f}" y="{y+p:.1f}" width="{s-2*p:.1f}" height="{s-2*p:.1f}" viewBox="{vb}">{inner}</svg>')

def icon(spec, x, y, s):
    kind, name = spec.split(":", 1)
    {"aws": aws_icon, "res": res_icon, "si": si_icon}[kind](name, x, y, s)

# --------------------------------------------------------------------------- shapes
def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def text(x, y, t, cls="s", fill=None, anchor=None):
    f = f' fill="{fill}"' if fill else ""
    a = f' text-anchor="{anchor}"' if anchor else ""
    add(f'<text x="{x}" y="{y}" class="{cls}"{f}{a}>{esc(t)}</text>')

def card(x, y, w, h, icons, title, lines=(), stroke="#2f3646", size=40, badge=None):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" class="card" stroke="{stroke}"/>')
    ix = x + 14
    iy = y + (h - size) / 2
    for spec in icons:
        icon(spec, ix, iy, size)
        ix += size + 8
    if badge:  # small secondary logo on the icon's corner
        icon(badge, ix - 8 - size * 0.45 + 4, iy + size * 0.55 + 4, round(size * 0.45))
    tx = ix + 6
    n = 1 + len(lines)
    ty = y + h / 2 - (n - 1) * 9.5 + 5
    text(tx, ty, title, "t")
    for i, line in enumerate(lines):
        text(tx, ty + 19 * (i + 1), line, "s")

def group(x, y, w, h, spec, label, color, dash="", fill="none", size=32):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}" stroke="{color}" stroke-width="2"{d}/>')
    if spec:
        icon(spec, x, y, size)
    text(x + size + 10, y + 21, label, "g", fill=color)

def arrow(d, cls="line"):
    add(f'<path d="{d}" class="{cls}"/>')

# --------------------------------------------------------------------------- canvas
W, H = 1800, 1050
add(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif">
<title>Chaos Arena architecture</title>
<defs>
  <clipPath id="round" clipPathUnits="objectBoundingBox"><rect width="1" height="1" rx="0.2"/></clipPath>
  <marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#c9cfdb"/></marker>
  <marker id="ahA" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#ffb020"/></marker>
  <marker id="ahR" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#ff4d5e"/></marker>
  <style>
    .card {{ fill: #161a22; stroke-width: 1.4; }}
    .t  {{ fill: #e8eaf0; font-size: 14.5px; font-weight: 650; }}
    .s  {{ fill: #9aa2b4; font-size: 12.5px; }}
    .g  {{ font-size: 15px; font-weight: 700; }}
    .lbl {{ fill: #c9cfdb; font-size: 12px; font-weight: 600; }}
    .line  {{ stroke: #c9cfdb; stroke-width: 1.6; fill: none; marker-end: url(#ah); }}
    .lineA {{ stroke: #ffb020; stroke-width: 1.8; fill: none; stroke-dasharray: 6 5; marker-end: url(#ahA); }}
    .lineR {{ stroke: #ff4d5e; stroke-width: 1.6; fill: none; stroke-dasharray: 5 4; marker-end: url(#ahR); }}
  </style>
</defs>
<rect width="{W}" height="{H}" fill="#0d0f14"/>''')

# Title
add('<text x="30" y="48" font-size="30" font-weight="800"><tspan fill="#ff4d5e">Chaos</tspan><tspan fill="#3d8bff"> Arena</tspan><tspan fill="#8a91a3" font-weight="600" font-size="20">  ·  architecture</tspan></text>')
text(30, 74, "A multiplayer tug-of-war you're allowed to crash, and it heals itself.", "s")

# --------------------------------------------------------------------------- left column
card(30, 116, 275, 70, ["res:Users"], "Players", ["browser or phone"], stroke="#3d8bff")
card(30, 214, 275, 70, ["res:Internet"], "DuckDNS", ["free domain → Elastic IP"])
card(30, 312, 275, 70, ["si:letsencrypt"], "Let's Encrypt", ["free HTTPS, auto-renewed"])
arrow("M167,186 L167,212")

# Self-healing ladder
add('<rect x="30" y="412" width="275" height="608" rx="10" class="card" stroke="#2f3646"/>')
text(48, 442, "Self-healing, layer by layer", "t")
rows = [
    ("si:docker", "App crashes (CHAOS)", "Docker restart · ~1 s"),
    ("si:gnubash", "App frozen", "health check → agent · < 2 min"),
    ("si:githubactions", "Broken release", "health-gated → auto rollback"),
    ("si:nginx", "Web container down", "host Nginx fallback page"),
    ("aws:architecture-service/AmazonCloudWatch", "OS hung / HW fault", "alarm → reboot / recover"),
    ("si:gmail", "Site unreachable", "uptime check → email"),
]
y = 466
for spec, t1, t2 in rows:
    icon(spec, 48, y, 34)
    text(94, y + 14, t1, "t", fill="#33d17a")
    text(94, y + 31, t2, "s")
    y += 66
text(48, 878, "Game state lives in DynamoDB,", "s")
text(48, 896, "so any container can die", "s")
text(48, 914, "without losing a point.", "s")
text(48, 950, "Recovery after a crash:", "s")
text(48, 972, "3.0 s (systemd) → ~1 s (Docker)", "t")

# --------------------------------------------------------------------------- AWS
group(330, 96, 1012, 924, "aws:architecture-group/AWSCloudlogoDark", "AWS Cloud", "#e8eaf0")
group(350, 142, 972, 862, "aws:architecture-group/Region", "Asia Pacific (Sydney) · ap-southeast-2", "#00a4a6", dash="8 5")

# EC2 instance group
group(370, 188, 560, 646, "aws:architecture-group/EC2instancecontents", "EC2 instance · t3.micro", "#ed7100")
card(388, 232, 172, 52, ["si:ubuntu"], "Ubuntu 24.04", size=30)
card(568, 232, 162, 52, ["res:AmazonEC2ElasticIPAddress"], "Elastic IP", size=30)
card(738, 232, 174, 52, ["si:linux"], "UFW + fail2ban", size=30)

card(388, 298, 524, 62, ["si:nginx"], "host Nginx", ["HTTPS · HTTP→HTTPS redirect · rate limit 100 req/s"])

group(388, 378, 524, 232, "si:docker", "Docker Compose · arena-net", "#2496ed", dash="5 4", size=28)
card(406, 420, 228, 82, ["si:nginx"], "web container", ["page + /api proxy", "127.0.0.1:8080 only"])
card(664, 420, 230, 82, ["si:nodedotjs"], "app container", ["Node.js + Express", "restart: unless-stopped"], stroke="#ff4d5e", badge="si:express")
card(664, 518, 230, 70, ["si:docker"], "volume arena-data", ["local mode only"], size=34)
text(410, 540, "health checks every 10 s", "s")
text(410, 558, "non-root · read-only files", "s")
text(410, 576, "CPU / memory / process limits", "s")

card(388, 628, 256, 84, ["aws:architecture-service/AmazonCloudWatch"], "CloudWatch agent", ["ships Nginx + deploy", "logs to CloudWatch"])
card(656, 628, 256, 84, ["si:gnubash"], "deploy agent", ["systemd timer, every minute", "pull · deploy · roll back · heal"], stroke="#ffb020")
card(388, 730, 524, 84, ["res:AWSIdentityAccessManagementRole"], "IAM role · chaos-arena-ec2-role",
     ["least privilege: one table, one bucket, its own logs", "temporary credentials via IMDSv2 · no access keys"], stroke="#33d17a")

# Managed services
card(960, 196, 340, 84, ["aws:architecture-service/AmazonDynamoDB"], "Amazon DynamoDB", ["managed NoSQL database", "game state · rounds · incidents"], size=46)
card(960, 296, 340, 84, ["aws:architecture-service/AmazonSimpleStorageService"], "Amazon S3", ["private · encrypted · 90-day cleanup", "score backups · incident reports"], size=46)
add('<rect x="960" y="396" width="340" height="150" rx="10" class="card" stroke="#2f3646"/>')
icon("aws:architecture-service/AmazonCloudWatch", 974, 410, 46)
text(1032, 428, "Amazon CloudWatch", "t")
text(1032, 447, "7 metric filters · 7 alarms", "s")
text(1032, 465, "dashboard · EC2 recover / reboot", "s")
for i, (spec, lab) in enumerate([("res:AmazonCloudWatchLogs", "Logs"), ("res:AmazonCloudWatchAlarm", "Alarms"), ("res:AmazonCloudWatchRule", "Filters")]):
    icon(spec, 980 + i * 102, 486, 32)
    text(1018 + i * 102, 507, lab, "s")
card(960, 562, 340, 84, ["aws:architecture-service/AmazonSimpleNotificationService"], "Amazon SNS", ["alarm notifications by email"], size=46)
card(960, 730, 340, 84, ["aws:architecture-service/AWSIdentityandAccessManagement"], "AWS IAM", ["role + least-privilege policy", "instance profile for EC2"], size=46)

card(370, 852, 560, 84, ["aws:architecture-service/AWSCloudShell"], "AWS CloudShell · infrastructure as scripts",
     ["setup-aws.sh · setup-monitoring.sh · teardown-aws.sh"], size=46)
add('<rect x="960" y="852" width="340" height="132" rx="10" class="card" stroke="#2f3646"/>')
text(978, 880, "Cost", "t")
text(978, 902, "AWS free plan credits", "s")
text(978, 921, "DynamoDB 5/5 capacity units", "s")
text(978, 940, "a few KB in S3 · logs kept 14 days", "s")
text(978, 959, "GitHub Actions + GHCR: free (public)", "s")

# --------------------------------------------------------------------------- GitHub
card(1380, 22, 392, 66, ["res:User", "si:gmail"], "Me (developer)", ["git push · pull requests · alert emails"], size=38)
group(1370, 110, 410, 910, "si:github", "GitHub", "#e8eaf0", dash="8 5")
card(1390, 156, 370, 66, ["si:github"], "Repository", ["main · pull requests · tags per module"])

add('<rect x="1390" y="242" width="370" height="334" rx="10" class="card" stroke="#33d17a"/>')
icon("si:githubactions", 1404, 256, 40)
text(1454, 274, "GitHub Actions · CI/CD", "t")
text(1454, 292, "on every push and pull request", "s")
steps = [
    ("si:nodedotjs", "test", "26 unit + API tests"),
    ("si:gnubash", "lint", "ShellCheck · Compose files"),
    ("si:docker", "build", "both images, layer cache"),
    ("si:docker", "integration test", "real containers, real CHAOS crash"),
    ("si:github", "publish (main)", "→ GitHub Container Registry"),
    ("si:githubactions", "deploy check", "live site runs this commit?"),
]
y = 312
for n, (spec, t1, t2) in enumerate(steps, 1):
    icon(spec, 1408, y, 30)
    text(1448, y + 13, f"{n}  {t1}", "lbl")
    text(1448, y + 28, t2, "s")
    y += 43

card(1390, 596, 370, 84, ["si:docker"], "GitHub Container Registry", ["chaos-arena-app · chaos-arena-web", "tags :sha-<commit> and :main"], stroke="#ffb020", badge="si:github")
card(1390, 700, 370, 70, ["si:dependabot"], "Dependabot", ["dependency-update pull requests"])
card(1390, 790, 370, 70, ["si:githubactions"], "Uptime check", ["from outside, twice an hour"])
add('<rect x="1390" y="880" width="370" height="120" rx="10" class="card" stroke="#2f3646"/>')
text(1408, 906, "Environments (same images everywhere)", "t")
text(1408, 928, "local · docker compose up (Docker volume)", "s")
text(1408, 947, "CI · GitHub runner (throw-away)", "s")
text(1408, 966, "production · EC2 + DynamoDB + S3", "s")
text(1408, 985, "only configuration differs", "s")

# --------------------------------------------------------------------------- arrows
arrow("M305,249 C350,249 352,329 386,329")                     # DuckDNS -> host Nginx
arrow("M305,347 C345,347 350,340 386,340", "line")             # cert
arrow("M640,360 L640,418")                                      # host nginx -> web (via docker)
arrow("M634,461 L662,461")                                      # web -> app
arrow("M894,446 C930,446 930,238 958,238")                      # app -> DynamoDB
arrow("M894,476 C940,476 940,338 958,338")                      # app -> S3
arrow("M912,560 C940,560 940,440 958,440")                      # docker logs -> CloudWatch
text(933, 604, "logs", "lbl")
arrow("M1130,546 L1130,560")                                    # CloudWatch -> SNS
arrow("M958,772 L914,772", "line")                              # IAM -> role
arrow("M1575,88 L1575,154")                                     # me -> repo
arrow("M1575,222 L1575,240")                                    # repo -> actions
arrow("M1575,576 L1575,594")                                    # actions -> ghcr
arrow("M1390,638 L1358,638 L1358,688 L914,688", "lineA")       # ghcr -> deploy agent
add('<text x="1090" y="704" class="lbl" fill="#ffb020" style="fill:#ffb020">pulls new images every minute</text>')
arrow("M1300,604 L1348,604 L1348,55 L1378,55", "lineR")         # SNS -> me (email)
add('<text x="1361" y="420" class="lbl" style="fill:#ff4d5e" transform="rotate(-90 1361 420)" text-anchor="middle">alarm emails</text>')

add("</svg>")
open(OUT, "w").write("\n".join(out))
print("wrote", OUT)
