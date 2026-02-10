# Deploy scaffold for VPS + EasyPanel

## One-time setup

1. Copy env template:
   ```bash
   cp .deploy.env.example .deploy.env
   ```
2. Fill `.deploy.env` with your VPS details.
3. Ensure SSH key auth works for your VPS host.

## Safety guarantees

- Deploy target must start with `PROJECT_PREFIX` (example `codex-*`).
- Only uses dedicated Docker network `DEPLOY_NAMESPACE`.
- Does not touch unrelated projects/apps.

## Run

```bash
./scripts/deploy.sh codex-myapp
```

This script currently validates the remote target and namespace isolation.
You can extend it with your app-specific build/run/EasyPanel API steps.
