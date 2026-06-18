# MedAsista Kong — Project Notes

## dokploy.md is the live env — MUST be synced to Dokploy manually

`dokploy.md` is **not** auto-loaded. It is the source of truth for the Dokploy
"Environment" panel. Every time we add / change / remove a variable there,
**the user must paste the diff into Dokploy UI** before the next redeploy,
otherwise compose still expands the old env and the change has no effect.

When editing `dokploy.md`, the assistant MUST:
1. Show the exact lines that changed (before -> after) in the response.
2. Call it out explicitly: "You need to update Dokploy env vars manually."
3. Never claim "done" without flagging the Dokploy sync.

Symptom of missed sync: container logs show old env, volume name mismatch,
port still old, `env | grep` inside container returns the previous value.

## Dokploy + custom-port services gotcha

Never hard-code a default container port in compose (e.g. `3000` for Grafana).
Always externalize it as an env var so future Grafana image bumps that change
the default do not silently break the route.

Canonical pattern (Grafana):
- `.env`: `GRAFANA_PORT=18101` (host), `GRAFANA_CONTAINER_PORT=3000` (container)
- compose ports: `"${GRAFANA_PORT}:${GRAFANA_CONTAINER_PORT}"`
- compose env: `GF_SERVER_HTTP_PORT: ${GRAFANA_CONTAINER_PORT}`
- Dokploy Domains panel records host port → Traefik → host:port → container:3000

If `GRAFANA_CONTAINER_PORT` is not in `.env`, Dokploy fails to expand the
variable and the container port mapping breaks. Always add both.

## Cloudflare tunnel + Dokploy Traefik + backend redirect loop (general rule)

Symptom: `ERR_TOO_MANY_REDIRECTS` on any `*.medasista.com` hostname routed through
the Cloudflare tunnel — affects Grafana today, affected Kafka UI when first
deployed, will hit any future public service that does scheme-aware redirects.

Cause: Cloudflare tunnel delivers HTTP to Dokploy Traefik; Traefik's websecure
router terminates TLS with Let's Encrypt and forwards to the backend as HTTP;
the backend sees scheme=http and 301-redirects to its public URL (https), the
browser follows, Cloudflare re-strips to http → loop.

Cloudflare SSL/TLS mode must be `Full` (not Flexible). Flexible will not save
you — same loop with extra Cloudflare hop.

Canonical fix — apply this pattern from day one to ANY new public-facing service:

1. **Traefik middleware** that injects `X-Forwarded-Proto=https`:
   ```
   traefik.http.middlewares.<name>-proxy-headers.headers.customRequestHeaders.X-Forwarded-Proto=https
   ```

2. **Router** attaches that middleware and uses the `web` entrypoint (plain HTTP):
   ```
   traefik.http.routers.<name>-public.entrypoints=web
   traefik.http.routers.<name>-public.middlewares=<name>-proxy-headers@docker
   ```

3. **Backend env** to trust the proxy headers (varies by framework):
   - Grafana:  `GF_SERVER_USE_PROXY_HEADERS: "true"` + `GF_SERVER_FORWARD_HEADERS: "true"`
   - Spring Boot (Kafka UI, future Java apps): `SERVER_FORWARD_HEADERS_STRATEGY: framework`

If a backend uses a different mechanism (e.g. flag, runtime config), find and
set the equivalent. Skipping this when copying labels from another service is
the most common cause of this bug — see kafka-ui history for the canonical
regression.

## VictoriaMetrics scrape config does not interpolate env vars

`/etc/victoriametrics/scrape.yaml` is bind-mounted into the container at start;
VictoriaMetrics does NOT expand `${VAR}` placeholders in mounted files. Hard-code
the Kong container DNS name and HTTPS port:

```yaml
static_configs:
  - targets:
      - 'uat-kong-gateway:18443'
```

For self-signed / Cloudflared TLS, add `tls_config.insecure_skip_verify: true`
on UAT, remove on prod.

## Cloudflare tunnel routes

Tunnel's "Published application routes" point to `dokploy-traefik:80` for both
domains. Actual Host-based routing is done by Dokploy Traefik from there. Do
NOT add compose-level Traefik labels for services whose domain is already
managed by Dokploy — they will collide.

## Cloudflare tunnel is only for the MedAsista team's own access

The tunnel exists so the user (working from home / a non-public Dokploy host)
can reach Kong Manager, Admin API, and Grafana over a private route. The
**public customer API** at `uat-api.medasista.com` MUST be exposed via
Dokploy's "Domains" panel directly — it does NOT go through the tunnel,
because end customers on the public internet hit Dokploy Traefik directly.

Do not propose adding customer-facing hostnames to the tunnel config.

## Grafana image version: pin to a release tag, never `latest`

`grafana/grafana:latest` resolves to the `nightly-slim` tag (rolling 12.x
pre-release). Two known problems on this image:

1. **Permission denied on plugin auto-install** — `plugins-bundled/` ships
   root-owned, Grafana runs as UID 472, log floods with `unlinkat ...:
   permission denied` errors.
2. **Breaking changes between nightly builds** — dashboards and config that
   worked yesterday may break tomorrow.

Use a release tag (`12.2.9`, `11.6.15`, etc.) and keep the volume on a fresh
name (`-v2`, `-v3`) when recreating so permission issues do not persist.

## No hard-coded values in compose — everything goes through env

Compose services must reference only env-var placeholders (`${VAR}`).
Hard-coded values like:

- Container ports: `3000`, `10001:10001`
- File ownership: `user: "10001:10001"`, `user: "472:472"`
- Internal paths: `/usr/share/grafana/data`
- Image build-time UIDs

...must be externalized to `dokploy.md` and consumed as `${ENV_VAR}` in compose.
Dokploy env panel is the only place where the actual value lives.

Why: Dokploy ignores the env file we keep in the repo. If a value is hard-coded
in compose, future bumps and platform-specific fixes (e.g. switching to a
different host UID) require editing compose and re-redeploying. With env,
you change one Dokploy env var.

Rule of thumb: if a value would change between environments (uat vs prod vs
laptop), it belongs in env. If it would change between deployments of the
same env (UID renumbering, port renumbering), it also belongs in env.

## User / Group IDs: one variable, not two

When the user and group of a container are the same number (typical for
single-UID images like Loki 10001:10001 or Grafana 472:472), use a single
`SERVICE_UID` env var and reference it twice in compose as
`${SERVICE_UID}:${SERVICE_UID}`. Do not create a separate SERVICE_GID
that holds the same value — one source of truth.

## Kong /metrics is internal only — never suggest external curl

The Kong Prometheus plugin's `/metrics` endpoint is only reachable from
the kong-net docker network. It is NOT behind Cloudflare Access and is
not designed to be hit from a host browser or curl.

To verify the scrape pipeline is alive, always go through Grafana:
`https://uat-kong-grafana.medasista.com` -> Explore -> VictoriaMetrics
datasource -> query `kong_request_count`. If a graph renders, the whole
Kong -> VM -> Grafana chain is working. Never propose `curl
https://uat-kong.medasista.com/metrics` as a verification step.

## Commit and push policy

The assistant is authorized to run `git commit` and `git push` on the
`uat` branch without explicit per-action approval from the user. Edit
the working tree, stage, commit with a clear conventional-commit message,
push. The user reviews `git log` and the live Dokploy env at their own
pace.

Still requires explicit confirmation:
- `git push --force` / `--force-with-lease` (rewrites shared history)
- `git reset --hard` to a non-HEAD commit
- Anything that drops commits other people may already have pulled
- Deleting branches that are not fully merged

When in doubt about a destructive op, ask once briefly with the proposed
command and a one-line "why".
