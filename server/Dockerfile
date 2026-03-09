FROM python:3.11-slim

# Python runtime defaults:
# - no .pyc files to keep image noise down
# - unbuffered logs so container logs appear immediately in CloudWatch/docker
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Install Python dependencies first so Docker layer caching is effective when
# only application code changes.
COPY server/requirements.txt /app/server/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r /app/server/requirements.txt

# Copy application source and bundled base model.
COPY server /app/server
COPY model /app/model

EXPOSE 8000

# Default values keep local docker runs simple while still allowing cloud
# platforms to override via environment variables.
ENV HOST=0.0.0.0
ENV PORT=8000

CMD ["python", "-m", "uvicorn", "app:app", "--app-dir", "/app/server", "--host", "0.0.0.0", "--port", "8000"]
