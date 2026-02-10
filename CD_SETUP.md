# Continuous Deployment to EasyPanel (Image-based)

This repository contains a minimal production-style CD setup:

- CI builds a Docker image and pushes it to a registry (template uses GHCR).
- CI triggers an EasyPanel deploy via API.
- EasyPanel service is configured to pull that image.

## One-time: EasyPanel service

1. Pick the hosting project: we use `app` (empty in your EasyPanel).
2. Create a service (example):

```bash
cd /Users/ertan/Documents/projects/test
./scripts/easypanel.sh create-image-service codex-myapp nginx:alpine app
```

3. Point the service to your real image (example GHCR):

```bash
./scripts/easypanel.sh set-image codex-myapp ghcr.io/<owner>/<repo>:main app
```

4. (Optional) Set env from a file:

```bash
./scripts/easypanel.sh set-env-file codex-myapp ./env/prod.env app
```

5. Deploy once manually:

```bash
./scripts/easypanel.sh deploy-service codex-myapp app
```

## One-time: GitHub repo secrets

Create these GitHub Actions secrets:

- `EASYPANEL_URL` = `http://72.60.23.237:3000`
- `EASYPANEL_API_KEY` = your API key
- `EASYPANEL_PROJECT` = `app`
- `EASYPANEL_SERVICE` = `codex-myapp`

On push to `main`, CI will:

- build+push `ghcr.io/<owner>/<repo>:main`
- call EasyPanel deploy

## Safety

All destructive ops are guarded:

- `scripts/easypanel.sh destroy-service ... --yes` only works for `codex-*`.
