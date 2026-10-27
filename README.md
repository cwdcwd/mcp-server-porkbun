# mcp-server-porkbun

Pinned, reproducible Docker deployment of the **official Porkbun MCP server**
(npm `@porkbunllc/mcp-server`) for the devpi06 MCP fleet, exposing the package's
**native Streamable HTTP connector**.

The fleet lane is hub-sweep bead `fleet-ops-3gf.9.1` (parent epic `fleet-ops-3gf.9`).
The wrapper contains **zero modified upstream code**: it pins the official
package, packages it into a digest-pinned container, and documents deployment.

## What runs

The official package ships two entry points:

- `dist/index.js` - stdio MCP server (local desktop clients)
- `dist/http.js` - **hosted-connector style Streamable HTTP server** (this is what the container runs)

The container runs `dist/http.js`. Credentials are validated **per request, upstream**,
so the service itself stores no Porkbun credentials anywhere: not in the image,
not in env, not in files, not in logs.

## Pin evidence (verify before trusting)

| Fact | Value |
|---|---|
| Official package (npm) | `@porkbunllc/mcp-server`, author Porkbun LLC (Owen Borseth, Porkbun CTO) |
| Pinned version | `0.52.0` (exact, no caret) |
| npm integrity | `sha512-y2mILv9j1kb2Mgul3XZM+5hffAy02lOht0sklrhZJuR6Ba7VRzao20UQd155UBjuVsqRy1MQ1LMusn/DgEVEPw==` |
| npm tarball digest match | sha512sum of `npm pack` tarball == registry integrity (verified on build host) |
| Upstream repository | `https://github.com/oborseth/Porkbun-MCP` (the `repository` field of the npm package) |
| Upstream tag | `v0.52.0` = commit `d59a214c446a6b2aa68be021b13ffef8d48373fb` (from `git ls-remote refs/tags`) |
| Container base | `node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914` (both stages) |
| Dependency pinning | committed `package-lock.json`; `npm ci` installs exactly those versions, which carry integrity hashes |

To re-verify any line without trusting this file:

```sh
npm view @porkbunllc/mcp-server@0.52.0 name version author repository dist.integrity
git ls-remote https://github.com/oborseth/Porkbun-MCP.git refs/tags/v0.52.0
npm pack @porkbunllc/mcp-server@0.52.0 && sha512sum porkbunllc-mcp-server-0.52.0.tgz
```

## Access gate: source-backed behavior

From the pinned package source (`dist/http.js`, per-request stateless

`StreamableHTTPServerTransport`):

- `/health` is served **before** the auth gate and returns only
  `{ ok, version, served }` - no credential material.
- Every MCP path (`/mcp`, `/mcp/no-topups`, `/mcp/no-purchases`) requires
  credentials on **every** request, before any MCP traffic:
  - no credential - `401` (JSON body: `unauthorized`);
  - malformed bearer - `401 invalid_token`;
  - well-formed key-pair bearer `Authorization: Bearer pk1_xxx:sk1_xxx`
    (or `X-API-Key` + `X-Secret-API-Key` headers) - validated upstream with a
    Porkbun `POST /ping`; invalid pair - `401 invalid_api_key`;
  - Porkbun API unreachable during validation - `503 api_unreachable` (fail-closed);
  - non-POST on MCP paths - `405`.
- Valid credential pairs are cached for ~30 seconds, keyed by a SHA-256 hash of
  the pair (never stored raw).

**Consequence for this deployment:** possession of a valid Porkbun key pair IS the
access credential. There is no separate service token and no auth bridge - per
the lane limits, the wrapper must not wrap or proxy upstream code. The effective
boundary is (a) this per-request upstream-validated gate, plus (b) the network
restriction on the host (below).

## Secret posture (why no .env exists here)

- The server never reads `PORKBUN_API_KEY` / `PORKBUN_SECRET_API_KEY` for HTTP
  serving: in the connector, per-request credentials override env credentials.
  The container is booted with **no credential env at all**.
- `PORKBUN_X402_PRIVATE_KEY` is deliberately **not set** - the USDC payment
  signer stays disabled and purchase tools cannot charge anything; the account's
  Porkbun-side $100/month spend limit is enforced upstream and untouched.
- The only env in the container: `HOST`, `PORT`, `MCP_PUBLIC_URL`,
  `npm_package_version` (User-Agent honesty) - all non-secret.

## Run (devpi06)

```sh
git clone https://github.com/cwdcwd/mcp-server-porkbun.git
cd mcp-server-porkbun
docker compose build
docker compose up -d
```

The compose file binds the port to two explicitly allowlisted host addresses
only: `192.168.0.190:3008` (the LAN IP the LiteLLM gateway reaches, same vantage
as the other MCP lanes on this host) and `127.0.0.1:3008` (local diagnostics).
Any other host address - including any tailscale address - does not expose the
port. Note this is a restriction on the *host exposure*; inside the container
`HOST=0.0.0.0` is required for docker-proxy to connect.

Port `3008` claimed by this lane on devpi06 (2026-10-27 census: ports
3000-3007 held by canon/balena/railway/vercel/godaddy/tailscale MCP lanes,
`pihole-mcp-ts` on host-network 3001, ollama on 11434).

## Verify (credential-free)

`scripts/probe.sh` runs the negative-control ladder - every check must pass
with **no** Porkbun credentials:

```sh
PROBE_BASE=http://192.168.0.190:3008 scripts/probe.sh
```

Checks: `/health` = 200 pre-gate; no-credential GET+POST on `/mcp` = 401;
malformed bearer = 401; wrong-length pk1/sk1 pair = 401 (local shape check);
well-formed fake pair = 401 **after upstream /ping validation**; unknown path = 404.

Real-credential serving (tools/list, tool calls) is exercised in the
verification stage only, by the owner/verifier with the owner key pair mounted
at the gateway - never by the builder (bead limits: no key handling, no
mutating API writes).

## Gateway mount configuration (credential-free)

The LiteLLM gateway (`ai.lan`) mounts the connector as an SSE/HTTP MCP server:

```yaml
# gateway mount (name suggestions follow the fleet's <app>-mcp convention)
url: http://192.168.0.190:3008/mcp
auth_type: bearer_token
auth_value: os.environ/PORKBUN_MCP_BEARER
```

The value of `PORKBUN_MCP_BEARER` is the account's Porkbun key pair in the
single-secret form the connector accepts:

`pk1_xxx:sk1_xxx`

That value is placed **only** in the gateway's protected environment file, by
the credential holder, and appears in no repository, host file, or log. The
connector validates it upstream on first use. (The gateway sends it as
`Authorization: Bearer pk1_xxx:sk1_xxx`, which the connector parses into the
key pair - source: `dist/http.js` `Authorization` regex.)

This resolves the "place the key on devpi06" step of the provisioning bead:
devpi06 stores **nothing**; the key's only runtime home is the gateway env.

## Operational notes

- **Recommended key scoping** (owner action at porkbun.com/account/api): create
  a dedicated key for agent use, set allowed IPs to the gateway egress and/or
  devpi06, restrict domains, and use "Manage, but no purchases" scope. The
  connector forwards whatever pair it is given; Porkbun enforces the scopes.
- **Profiles:** `/mcp` (full surface; sandbox-only tools excluded), plus
  `/mcp/no-topups` and `/mcp/no-purchases` (narrower directory variants) are
  served under the same gate. The gateway mounts `/mcp` - full tool surface.
- **Money surface:** purchase/funding tools exist on `/mcp` but every mutation
  is gated upstream by the key's scope and the account spend limit; the x402
  wallet signer is disabled in this deployment (see above).
- **Logs:** json-file driver, 10MB x 3. The connector's request logs carry
  method, path, status, timing - never tokens, keys, or bodies (upstream docs).
- **Upgrades:** bump the exact version in `package.json`, delete and regenerate
  `package-lock.json` (`npm install --package-lock-only`), re-verify the pin
  table (new npm integrity + upstream tag), update `npm_package_version` in the
  Dockerfile, rebuild, re-probe.

## npm security advisories in the pinned tree

`npm audit --omit=dev` on 2026-10-27: **4 HIGH, 0 CRITICAL**, all rooted in the
`zod` dependency, reached via `@x402/core`/`@x402/evm` (the USDC wallet path,
which is **disabled** in this deployment - see above) and via the pinned
package itself. The pin is deliberate: this wrapper does not override an
official dependency, and `npm audit fix` would deviate the lockfile from the
released package. The advisories clear with a semver-minor `zod` update
available upstream; on the next upstream version bump, follow the upgrade
procedure, regenerate the lockfile, and re-verify. CI runs the audit
report-only (`.github/workflows/verify.yml`).

## Verification evidence matrix

| Check | Status |
|---|---|
| npm registry pin + tarball integrity match | VERIFIED (evidence on the bead) |
| Upstream tag/commit match for the pinned version | VERIFIED (evidence on the bead) |
| Build host lockfile regenerated and committed | VERIFIED (lockfile `npm ci` on devpi03 + in-container) |
| Pre-push local HTTP boot + negative probes (node run) | VERIFIED (evidence on the bead) |
| Container build + boot on devpi06, healthcheck green | NOT RUN - the container build ran in CI only; the devpi06 container boot is deferred to the deployment/verification stage (bds .9.2/.9.3) |
| Negative-control ladder on devpi06 (all credential-free) | NOT RUN - the 7/7 ladder is verified on devpi03 (bare node run) and inside CI's container, never against a devpi06-hosted instance; deferred to .9.2/.9.3 |
| LAN-reachability from the gateway vantage, unauthenticated 401 | NOT RUN - deferred to .9.2/.9.3; needs the live devpi06 endpoint plus a gateway-vantage probe |
| Real-credential serving (tools/list) | LEFT TO VERIFICATION STAGE (owner key at gateway) |