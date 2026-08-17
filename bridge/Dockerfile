FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    BRIDGE_CONFIG=/config/config.yaml \
    DEBIAN_FRONTEND=noninteractive

# platform-tools provides adb used to drive Cuttlefish SET_STATE intents
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        adb \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY config.yaml /config/config.yaml

# Default config can be overridden by bind-mounting /config/config.yaml
VOLUME ["/config"]

CMD ["python", "-u", "main.py", "-c", "/config/config.yaml"]
