# The healer as a container, so it can run inside the cluster (Deployment + ServiceAccount)
# instead of from a laptop kubeconfig.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY healer.py .
# Non-root; the log goes to a writable temp path and to stdout (kubectl logs).
RUN useradd --system --uid 10001 healer
USER 10001
ENV HEALER_LOG_FILE=/tmp/self_healing.log
CMD ["python", "-u", "healer.py"]
