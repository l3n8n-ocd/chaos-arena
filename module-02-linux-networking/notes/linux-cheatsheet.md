# Linux Cheat Sheet — what I used in Module 02

## Moving around & files
| Command | What it does |
|---|---|
| `pwd` | Print the folder I'm in |
| `ls -la` | List all files (including hidden) with permissions |
| `cd /srv/chaos-arena` | Change folder (`cd ~` = home, `cd ..` = up one) |
| `mkdir -p a/b/c` | Make folders (and parents) |
| `cp`, `mv`, `rm` | Copy, move/rename, delete (`rm -r` for folders — careful!) |
| `cat`, `less`, `tail -f file` | Show a file, scroll a file, follow a growing log |
| `nano file` | Simple text editor (`Ctrl+O` save, `Ctrl+X` exit) |
| `tree -L 2` | Show folders as a tree |

## Permissions
`ls -l` shows something like `-rwxr-xr-x  1 deployer arena ...`

```
- rwx r-x r-x
│  │   │   └── others  : read, execute
│  │   └────── group   : read, execute
│  └────────── owner   : read, write, execute
└───────────── type    : - file, d directory, l link
```

Numbers: **r = 4, w = 2, x = 1**. Add them per group:

| Mode | Meaning | Used for |
|---|---|---|
| `600` | owner read/write only | private keys, `authorized_keys` |
| `644` | owner rw, everyone read | config files, web pages |
| `700` | owner only | `~/.ssh` folder |
| `755` | owner all, others read+enter | scripts, public folders |
| `2775` | setgid + group can write | `/srv/chaos-arena` (shared team folder) |

```bash
chmod 640 file              # set permissions
chmod +x script.sh          # make a script executable
chown deployer:arena file   # change owner:group
```
**setgid on a folder (the `2` in 2775):** new files inside automatically belong to the folder's group, so the whole team can keep editing them.

## Users & groups
```bash
whoami                      # who am I
id deployer                 # user's UID, GID and groups
sudo useradd -m -s /bin/bash -G arena deployer   # create user
sudo usermod -aG arena ubuntu    # ADD to group (-a is important! without it you replace groups)
groups                      # my groups (new groups need a re-login)
sudo -l -U deployer         # what can this user run with sudo?
getent group arena          # members of a group
```

## Processes
```bash
ps aux                      # every running process
ps -eo pid,user,%mem,comm --sort=-%mem | head   # top memory users
htop                        # live view (q to quit)
pgrep -a nginx              # find processes by name
kill <PID>                  # ask a process to stop (SIGTERM)
kill -9 <PID>               # force kill (SIGKILL) — last resort
free -h                     # RAM & swap
df -h                       # disk space
uptime                      # how long running + load
```

## Services (systemd)
```bash
systemctl status nginx      # is it running? recent logs
sudo systemctl start|stop|restart|reload nginx
sudo systemctl enable nginx # start on boot
systemctl is-active nginx
journalctl -u nginx -f      # follow a service's logs (Ctrl+C to stop)
journalctl -u ssh --since "1 hour ago"
```
In Module 03, Chaos Arena itself will become a systemd service that restarts automatically when it crashes.

## SSH keys
- A key pair = **private key** (stays on my PC, e.g. `chaos-arena-key.pem`) + **public key** (on the server in `~/.ssh/authorized_keys`).
- The server sends a challenge only the private key can answer, so no password ever travels over the network.
```bash
ssh-keygen -t ed25519 -C "my laptop"   # create a new key pair
ssh chaos-arena                        # connect using ~/.ssh/config
scp file chaos-arena:~/                # copy a file to the server
sudo sshd -T | grep passwordauth       # show the effective SSH setting
```

## Packages
```bash
sudo apt update             # refresh the package list
sudo apt upgrade            # install updates
sudo apt install nginx      # install a package
apt list --installed | grep nginx
```
