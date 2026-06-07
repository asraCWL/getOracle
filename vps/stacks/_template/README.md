# &lt;app-name&gt;

Per-app folder on the VPS. Copy this `_template/` to `/opt/stacks/<app>/` (or clone
your repo there). Full guide: `/opt/stacks/README.md` (a.k.a. `vps/HANDOVER.md`).

## Layout
    <app>/
      docker-compose.yml   # how it runs
      Dockerfile           # how it builds
      .env                 # secrets/config (gitignored — copy from .env.example)
      data/                # persistent state/output (gitignored)
      <your code>

## Run as a service (always-on)
    cp .env.example .env      # then edit
    docker compose up -d --build
    docker compose logs -f

## Run as a scheduled job (timer → run → exit)
Leave `restart:` out, then trigger from a systemd timer:
    docker compose run --rm app
See the "Scheduled jobs" section of the handover for ready-to-paste timer units.
