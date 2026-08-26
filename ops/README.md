# Two-node DGX Spark deployment

This toolkit deploys the repository on `192.168.1.252` (head) and
`192.168.1.64` (worker). The worker is reached from the head over the existing
`spark-worker-cx7` passwordless SSH alias and the 200G private fabric.

The public model is downloaded exactly once, on the head. During both the
runtime-image pull and model download, Linux IFB/TBF ingress shaping caps the
head Wi-Fi interface at 235 Mbit/s (29.375 MB/s). The verified image and cache
are then copied to the worker over the private fabric, so the worker never
downloads the model from the Internet.

The configured Nanjing University GHCR mirror exposes the same immutable
manifest digest pinned by the project (`sha256:a839...d8`); only the transport
origin changes. The model itself uses the Hub-compatible endpoint in
`config.env` and remains pinned to the repository's tested revision.

The vLLM process binds only to `127.0.0.1:8888`. Nginx exposes
`http://192.168.1.252:8000/v1/` and `/health`; every other route is rejected.
This matters because upstream vLLM API-key protection does not cover every
inference-capable compatibility route.

Main commands on the head:

```bash
sudo ./ops/install.sh
sudo ./ops/download-model-limited.sh
./ops/sync-worker.sh
./validate-dspark-config.sh
./start-deepseek-v4-flash-dspark.sh
sudo ./ops/finalize-deployment.sh
./ops/healthcheck.sh
./ops/status.sh
./ops/logs.sh --follow
```

Secrets are kept only in the remote `.env.dspark` (mode 0600). They are not
written to `ops/config.env` or committed to Git.
