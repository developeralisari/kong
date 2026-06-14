# MedAsista Kong — Project Notes

## Dokploy + custom-port services gotcha

When a service uses a non-default container port (e.g. Grafana on host 18101
instead of default 3000), the **Dokploy Domains panel** records the host port
and Traefik forwards to that port on the container. Two things must match:

1. Compose `ports:` mapping must expose that port on the host.
2. The process **inside the container** must actually listen on that port.

For Grafana that means adding `GF_SERVER_HTTP_PORT: ${GRAFANA_PORT}` to env.
Without it Grafana keeps listening on 3000, Dokploy Traefik hits 18101, gets
"Bad Request" (not 502 / not redirect loop — easy to misdiagnose).

Same trap applies to any service using a non-default internal port.

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
