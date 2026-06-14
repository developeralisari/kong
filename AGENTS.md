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

## Cloudflare tunnel + Dokploy Traefik + Grafana redirect loop

Symptom: `ERR_TOO_MANY_REDIRECTS` on `https://uat-kong-grafana.medasista.com`.

Cause: Cloudflare tunnel delivers HTTP to Dokploy Traefik; Traefik's websecure
router terminates TLS with Let's Encrypt and forwards to Grafana as HTTP; Grafana
sees scheme=http and 301-redirects to its `GF_SERVER_ROOT_URL` (https), browser
follows, Cloudflare re-strips to http → loop.

Fix: env must include:
```
GF_SERVER_USE_PROXY_HEADERS: "true"
GF_SERVER_FORWARD_HEADERS: "true"
```

Cloudflare SSL/TLS mode must be `Full` (not Flexible). Flexible will not save
you — same loop with extra Cloudflare hop.

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

## Kong /metrics is internal only — never suggest external curl

The Kong Prometheus plugin's `/metrics` endpoint is only reachable from
the kong-net docker network. It is NOT behind Cloudflare Access and is
not designed to be hit from a host browser or curl.

To verify the scrape pipeline is alive, always go through Grafana:
`https://uat-kong-grafana.medasista.com` -> Explore -> VictoriaMetrics
datasource -> query `kong_request_count`. If a graph renders, the whole
Kong -> VM -> Grafana chain is working. Never propose `curl
https://uat-kong.medasista.com/metrics` as a verification step.
