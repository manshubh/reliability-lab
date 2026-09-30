# Reliability Lab

A small production-like system that breaks itself on purpose, recovers, and publishes what happened.

> **Under construction.** For now, the repository checks, the local cluster and its gateway work, with a stand-in behind the gateway until the real services land. This README grows as each part lands.

## What it will do

Every night, a CI job will:

1. Build a throwaway Kubernetes cluster.
2. Run a set of failure experiments against a small demo system: crashed instances, a slow database, a payment provider that disappears, a bad release, lost data.
3. Judge each experiment against service level objectives set in advance.
4. Publish a report, then delete everything.

The same commands run the whole thing on a laptop.

The point is evidence rather than claims. Each experiment states a hypothesis with numbers, and the report says whether the system held up. A change that makes the system less resilient fails the run, the way a broken function fails a unit test.

## Roadmap

1. **Foundations:** one entry point, and every file checked on every pull request. *(in progress)*
2. **The system and its telemetry:** four small Go services and Postgres on a local cluster, with metrics, logs and dashboards.
3. **Defining reliability:** SLOs, burn-rate alerts, runbooks and a baseline traffic profile.
4. **The game day engine:** experiments as data files, a runner that judges them, and a report per run.
5. **Nightly runs and a public site** with history and trends.
6. **Safe change:** gradual rollouts that roll back on their own.
7. **Capacity, limits and platform faults.**
8. **Data protection:** backups and timed restore drills.
9. **Polish and the write-up.**

## Repository layout

Folders appear as their first content lands.

| Path | What lives there |
| --- | --- |
| `Makefile` | The single entry point. Run `make help`. |
| `app/` | The demo system: Go services and their tests, in one Go module. |
| `platform/` | Everything the cluster needs, as code: cluster, gateway, observability, data. |
| `reliability/` | SLO definitions, the source of truth, and the alerts and dashboards generated from them. |
| `experiments/` | One data file per failure experiment. |
| `load/` | Traffic profiles. |
| `tools/` | Python tools in one uv workspace: checks, game day runner, report builder. |
| `site/` | Static site templates. The built site is never committed. |
| `docs/` | Architecture, runbooks and postmortems. |
| `.github/workflows/` | CI. Every step calls a make target, so CI and a laptop run the same thing. |

## Quick start

You need:

- macOS or Linux.
- A Docker-compatible runtime whose VM has **4 CPUs and 10 GB of memory**. This laptop profile keeps timing close to the free CI runner (4 vCPUs, 16 GB). The memory is lower because a 16 GB laptop can't give a VM 16 GB.
  - OrbStack: `orb config set cpu 4`, `orb config set memory_mib 10240`, then restart OrbStack.
  - Colima: `colima start --cpu 4 --memory 10`.
  - Docker Desktop: Settings → Resources.
- [mise](https://mise.jdx.dev), which installs every other tool at a pinned version.

Then:

```sh
make tools   # install the pinned tools
make help    # list every target
make pr      # run the same checks as a pull request
```

`make tools` also installs the Helm plugin helm-diff. Helm and helmfile keep all their state in `.cache/` in the repository, never in your home directory.

To run the local cluster (one control plane and three workers, one per zone, an image registry, and the gateway):

```sh
make up                                            # create it, or repair it; safe to run again
kubectl get nodes -L topology.kubernetes.io/zone   # every node Ready, workers in zones a, b and c
make smoke                                         # check every user journey through the gateway
curl -i localhost:8080/catalog                     # one request, the way a user sends it
make down                                          # delete everything make up created
```

`make up` sets kubectl's current context to `kind-lab`. If mise isn't activated in your shell, run the pinned kubectl as `mise exec -- kubectl`.

The cluster listens on 127.0.0.1 only: port 8080 for the gateway, 3000 for Grafana and 5001 for the image registry. If 8080 or 3000 is taken, pick other ports when you create the cluster, for example `LAB_GATEWAY_PORT=18080 LAB_GRAFANA_PORT=13000 make up`.

## The front door

Every request enters through one gateway: [Traefik](https://traefik.io), configured only through the Kubernetes [Gateway API](https://gateway-api.sigs.k8s.io). Its files are in `platform/gateway/`.

- **Where requests go.** Port 8080 on your machine reaches a NodePort on the cluster, which forwards each request to one of two Traefik pods, in different zones, so the loss of a node doesn't close the door. Traefik sends it on to the `api` Service in namespace `app`. For now, `api` is a stand-in that answers 200 to everything.
- **How journeys are routed.** Each user journey has its own HTTPRoute: `browse` (`GET /catalog`), `place-order` (`POST /orders`) and `view-order` (`GET /orders/<id>`). Anything else gets a 404. A `PathPrefix` match covers whole path segments and ignores a trailing slash, so `GET /orders` also matches `view-order` (`/orders/`); that is how the Gateway API defines it.
- **Where the metrics come from.** Traefik counts and times every request it serves. The route's name is part of the `router` label of `traefik_router_requests_total` and `traefik_router_request_duration_seconds`, so each journey's SLOs are measured at the gateway, and the duration buckets include the SLO thresholds, 250 ms and 500 ms. Traefik gives up on a backend after 15 s and answers 504, so even a hung request is counted.

## Contributing

Run `make pr` before you push. The pull request check runs exactly the same thing.

To run the fast linters on every commit, install the hooks in `.pre-commit-config.yaml` with `prek install` (or `pre-commit install`).

## License

[Apache-2.0](LICENSE).
