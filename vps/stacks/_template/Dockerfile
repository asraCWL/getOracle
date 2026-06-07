# Generic Python automation image. Adjust per project (base tag, system deps, CMD).
FROM python:3.12-slim

# System deps kept minimal. Add per project as needed, e.g.:
#   - build-essential        (packages that compile C extensions)
#   - a vendored CLI binary  (download the linux/arm64 build — this host is aarch64)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=Europe/Copenhagen \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install deps first for better layer caching.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Long-running service: keep the main process in the foreground (PID 1).
# Scheduled job: this CMD is what the timer runs via `docker compose run --rm app`.
CMD ["python", "main.py"]
