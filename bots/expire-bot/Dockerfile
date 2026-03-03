FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libolm-dev gcc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY bot.py .

RUN useradd -r -s /bin/false bot && mkdir -p /data && chown bot:bot /data

USER bot
VOLUME /data

ENV EXPIRE_BOT_CONFIG=/data/config.yaml

HEALTHCHECK --interval=60s --timeout=5s --retries=3 \
  CMD python -c "import os, sys; sys.exit(0 if os.path.exists('/data/store/session.json') else 1)"

CMD ["python", "-u", "bot.py"]
