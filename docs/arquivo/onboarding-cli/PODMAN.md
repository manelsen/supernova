# Supernova with Podman

## Install / First Run

1. Install Podman and Podman Compose.
2. Copy quickstart config:

```sh
cp examples/quickstart/supernova.yaml supernova.yaml
```

3. Set secrets using environment or `.env`.
4. Start services:

```sh
podman compose up -d
```

## Configuration

- Runtime configuration remains `supernova.yaml`.
- Compose definitions from `docker-compose.yml` are compatible with Podman Compose in most environments.
- For rootless networking differences, verify exposed ports and host mapping.

Useful commands:

```sh
podman compose ps
podman compose logs -f supernova
```

## Scaling

Scale service replicas:

```sh
podman compose up -d --scale supernova=3
```

Operational notes:

- Validate load distribution and channel webhook/polling constraints.
- Ensure persistent volumes and DB throughput are sized for concurrency.

## Interaction

- Interact with Supernova through configured channels and watch runtime logs.
- Use health/log output to validate adapter startup and message processing.

## Stop / Uninstall

Stop stack:

```sh
podman compose down
```

Stop and remove volumes:

```sh
podman compose down -v
```

Remove dangling images:

```sh
podman image prune -f
```

