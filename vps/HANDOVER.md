# VPS Handover — `oracle-arm-vps` automation host

This box is a general-purpose host for small automation projects (trading bots,
scrapers, scheduled jobs, advisors — things like `PolyMarketBot`, `SaxoTrader`,
`RCAutomations`). It is set up so each new project is a quick, repeatable drop-in.

This doc is the single source of truth for **what the box is**, **what's already
configured**, and **how to deploy a new project**. A copy lives on the box at
`/opt/stacks/README.md`.

---

## 1. The box

| | |
|---|---|
| Name | `oracle-arm-vps` (Oracle Cloud, tenancy `asamr`, **Pay-As-You-Go**) |
| Shape | `VM.Standard.A1.Flex` — 4 OCPU / 24 GB RAM / 200 GB disk (ARM64 / aarch64) |
| OS | Ubuntu 24.04 LTS |
| Region | eu-stockholm-1, AD-1 |
| Public IP | **79.76.42.0** (reserved — survives reboot/stop/rebuild) |
| Cost | ~$0/mo (4/24 sits inside Oracle's always-free Ampere allowance) |
| Login | `ssh oracle` (aliases `getoracle`, `oracle-arm`; user `ubuntu`, key `~/.ssh/getoracle.key`) |
| Timezone | Europe/Copenhagen |

> ⚠️ **Architecture is ARM64.** When a project needs a prebuilt binary/CLI, grab the
> `aarch64` / `arm64` Linux build, not x86_64. (Most images on Docker Hub are
> multi-arch and "just work"; vendored binaries are the thing to watch.)

---

## 2. What's already configured (the base)

- **Docker Engine + Compose plugin** (`docker compose ...`). `ubuntu` is in the
  `docker` group, so no `sudo` needed.
- **Container log rotation** — `/etc/docker/daemon.json` caps logs at 10 MB × 3 per
  container, so a chatty app can't fill the disk.
- **4 GB swap** (`/swapfile`), `vm.swappiness=10`.
- **Automatic security updates** (`unattended-upgrades`).
- **fail2ban** — bans IPs that brute-force SSH (5 tries → 1 h ban).
- **SSH hardened** — key-only (passwords disabled), keyboard-interactive off. (This
  came hardened from the OCI image.)
- **Firewall** — the OCI image's `iptables` (via `netfilter-persistent`) allows only
  port **22** inbound; everything else is rejected. Plus the cloud-level **OCI
  Security List**. Opening web ports is a deliberate two-step (see §6).

Nothing else is installed. No reverse proxy yet (add when a project needs a public
domain — see §7).

---

## 3. The convention: one folder per app

Everything lives under **`/opt/stacks/`** (owned by `ubuntu`):

    /opt/stacks/
      README.md            # a copy of this handover
      _template/           # skeleton to copy for a new app
      <app>/               # one folder per project
        docker-compose.yml
        Dockerfile
        .env               # secrets/config — gitignored, never committed
        data/              # persistent state/output — gitignored
        <code>

Rules of thumb:
- **Secrets** → `.env` only (copy from `.env.example`). Never in git, never in the image.
- **Persistent data** (sqlite, output, downloads) → `./data`, mounted into the container.
  Everything else in a container is disposable.
- **Time-sensitive code** → containers default to UTC; set `TZ=Europe/Copenhagen`
  (the template does this) if the app cares about local time.

---

## 4. Deploy a new app — two patterns

Pick based on whether the thing runs continuously or on a schedule.

### Pattern A — Long-running service (always-on, restart on crash)
For daemons: a 24/7 bot, a web service, anything that should stay up.

    cd /opt/stacks
    git clone https://github.com/asraCWL/<app>.git <app>     # or: cp -r _template <app>
    cd <app>
    cp .env.example .env && nano .env                        # fill in secrets
    docker compose up -d --build                             # start (restart: unless-stopped)
    docker compose logs -f                                   # watch it

Docker is the supervisor here — `restart: unless-stopped` brings it back after a
crash or a reboot. No systemd/launchd needed.

### Pattern B — Scheduled job (run on a timer, then exit)
For periodic tasks: a daily scraper, an hourly sync (e.g. RCAutomations' 07:00 post).
Keep the same compose file but **omit `restart:`**, and trigger it with a systemd
timer. Two small files:

`/etc/systemd/system/<app>.service`:

    [Unit]
    Description=<app> scheduled run
    After=docker.service
    Requires=docker.service

    [Service]
    Type=oneshot
    WorkingDirectory=/opt/stacks/<app>
    ExecStart=/usr/bin/docker compose run --rm app

`/etc/systemd/system/<app>.timer`:

    [Unit]
    Description=Run <app> daily at 07:00 Europe/Copenhagen

    [Timer]
    OnCalendar=*-*-* 07:00:00
    Persistent=true

    [Install]
    WantedBy=timers.target

Then:

    sudo systemctl daemon-reload
    sudo systemctl enable --now <app>.timer
    systemctl list-timers <app>.timer        # confirm next run
    journalctl -u <app>.service -f           # see job output

(Timers honor the host timezone, already Europe/Copenhagen. `Persistent=true` runs a
missed job after downtime.)

> Quick-and-dirty alternative for a throwaway script: a plain `python` venv +
> `crontab -e`. Fine for experiments; Docker is better once it matters.

---

## 5. Reaching a web UI (SSH tunnel — no public exposure)

If an app serves a dashboard, bind it to **localhost** in compose
(`127.0.0.1:PORT:PORT`) and tunnel in from your laptop:

    ssh -L 8765:localhost:8765 oracle
    # then open http://localhost:8765 in your browser

The panel is only reachable by someone who can SSH in. This is the default for
anything sensitive (e.g. a money-bot control panel). Public exposure is opt-in (§6/§7).

---

## 6. Opening public ports (only when a project needs inbound web)

Two gates must both allow the port. Example for HTTP/HTTPS:

**a) Host firewall** (insert before the REJECT rule, then persist):

    sudo iptables -I INPUT 6 -p tcp --dport 80  -m state --state NEW -j ACCEPT
    sudo iptables -I INPUT 6 -p tcp --dport 443 -m state --state NEW -j ACCEPT
    sudo netfilter-persistent save

**b) OCI Security List** (cloud firewall) — add ingress rules for the same ports.
Console: VCN `VCNN ar` → Security Lists → add stateful ingress `0.0.0.0/0` → TCP 80, 443.
(Or via the OCI CLI/API.)

> Docker note: Docker writes its own iptables rules. Ports you publish to `0.0.0.0`
> generally work, but if a published port seems blocked, it's almost always gate (b),
> the OCI Security List, not Docker.

---

## 7. Adding HTTPS / a domain later (reverse proxy)

Not installed (YAGNI). When a project needs a real domain with auto-HTTPS, the clean
add is **Caddy** as a shared proxy in `/opt/stacks/proxy/` on a shared `web` Docker
network: point an `A` record at `79.76.42.0`, list the site in a `Caddyfile`, and
Caddy fetches/renews Let's Encrypt certs automatically. ~5 minutes when needed.

---

## 8. Adding another machine (e.g. the work laptop)

SSH is key-only, so a new machine just needs its **public key** added — passwords
stay disabled. On the new machine:

    ssh-keygen -t ed25519              # if it has no key yet
    cat ~/.ssh/id_ed25519.pub          # copy this line

Then append that line to the server (run from a machine that already has access):

    ssh oracle 'echo "PASTE_THE_PUBLIC_KEY_LINE" >> ~/.ssh/authorized_keys'

Each machine gets its own key; revoke one by deleting its line from
`~/.ssh/authorized_keys`. (On a Windows work laptop, do this inside WSL2.)

---

## 9. Day-to-day operations

| Task | Command |
|---|---|
| List running apps | `docker ps` |
| App logs | `cd /opt/stacks/<app> && docker compose logs -f` |
| Update an app | `git pull && docker compose up -d --build` |
| Restart / stop | `docker compose restart` / `docker compose down` |
| Disk / memory | `df -h` / `free -h` / `htop` |
| Reclaim space | `docker system prune -af` (removes unused images/containers) |
| Back up an app's data | copy its `./data` dir off-box (e.g. `scp -r oracle:/opt/stacks/<app>/data ./`) |
| Scheduled job status | `systemctl list-timers` |

Backups: state lives in each app's `data/`. There's no automatic off-box backup —
for anything important (e.g. a bot's `state.db`), copy `data/` somewhere safe on a
schedule. The OS itself is reproducible from this doc; the **data** is what's precious.

---

## 10. Per-project gotchas to carry over

When you migrate a specific project (separate session/repo), watch for:

- **Vendored CLIs/binaries** → use the **arm64 / aarch64** Linux build (this host is ARM).
- **Interactive auth** (e.g. a `login` CLI that stores creds in `~/.something`) → run it
  once inside the container (`docker compose run --rm app <login-cmd>`) and persist that
  dir as a named volume so it survives rebuilds.
- **Single-instance / live-money services** → make sure the same instance isn't also
  running on another machine. Carry over any state DB so the app isn't "blind" to
  in-flight work.
- **Python version** → pin it in the Dockerfile (`python:3.12-slim` here) if the code
  needs a specific version.
