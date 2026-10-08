# ADR-0014: Two OTP pins, the container's and the desktop's, and a TLS 1.2 clamp between them
Status: accepted · Date: 2026-10-08

## Context

OTP 28.5.0.7 (released 2026-09-22) fixes CVE-2026-89422 (GHSA-rgxr-4g4w-j875, `ssl`, CVSS 4.0
9.3 Critical): OTP's TLS 1.3 client completes a handshake without validating the server's
certificate when the ServerHello carries a `pre_shared_key` extension the client never offered. Every
outbound HTTPS call Trinity makes (model providers, MCP servers, web fetch, model downloads) is a TLS
client, so anyone on the network path can impersonate any of them. The advisory's workaround is
"Restrict affected clients to TLS 1.2 ({versions, ['tlsv1.2']}) until the patch is applied. No
configuration both keeps TLS 1.3 and mitigates the issue." The same release fixes CVE-2026-65634
(`asn1`, 8.2 High, a crafted OID costs CPU during a TLS handshake) and CVE-2026-68956 (the `ssh`
daemon, which Trinity does not run).

Until this ADR one file, `.tool-versions`, pinned OTP for everything, and ADR-0005 set that pin to the
newest OTP whose ERTS Burrito can download for every desktop target. Burrito 1.6.0 fetches Linux and
macOS ERTS from a third-party CDN and Windows from the OTP release page
(`deps/burrito/lib/util/erts_universal_machine_fetcher.ex`). Probed 2026-10-08:

| OTP | Linux x86_64 | Linux aarch64 | macOS universal | Windows |
|---|---|---|---|---|
| 28.5.0.6 | 200 | 200 | 200 | 200 |
| 28.5.0.7 | 404 | 404 | 404 | 200 |

So the desktop cannot have 28.5.0.7 yet. The container images can: the hardened headless image
(`ci/ironbank/`) and the FIPS leg's image (`ci/fips/Containerfile`) build OTP from source and never
touch Burrito. The hardened image's vulnerability check was failing on 14 findings, every one in
`erlang-28.5.0.5`, CVE-2026-89422 among them, and tying the container to the desktop's pin meant
the container waited on a CDN it does not use.

The owner decided this on 2026-10-08 (decision D2): the container to 28.5.0.7 now; the desktop to
28.5.0.6 on all three targets with every outbound BEAM TLS client clamped to TLS 1.2; a test that
enumerates the clients and asserts the clamp; a daily canary that opens the pull request moving the
desktop pin when Burrito has the ERTS. A custom ERTS build was considered and rejected: macOS is
feasible, Windows is unnecessary, and Linux is blocked by Burrito issue #237 (custom ERTS fails to
compile its wrapper in 1.6.0).

## Decision

**Two pins.** `ci/container.tool-versions` names the OTP the container images build (28.5.0.7);
`.tool-versions` names the desktop's and the gate's (28.5.0.6). `fips-image.yml` reads the container
pin, and `scripts/fips_image_tag.sh` hashes it. ADR-0005 still governs the desktop pin.

**The lint holds the pins together rather than equal.** `mix trinity.ironbank.lint` used to require
the submission's OTP resource to be the OTP `.tool-versions` names. That rule is what tied the
container to Burrito, so it now requires the resource to be the OTP `ci/container.tool-versions`
names, and adds two rules of its own: both pins are the same OTP major, because one compiled tree and
one Elixir build run on both; and the container's is never older than the desktop's, because the
container is the pin that can move the day OTP publishes a fix. Dropping the check instead would have
let the manifest and the declared pin drift apart unnoticed.

**The clamp is keyed on the running `ssl` application.** `Trinity.TLS.affected?/0` compares the
loaded `ssl` version with the first fixed one for the runtime's OTP major (`ssl` 11.6.0.6 on OTP 28,
from OTP's `otp_versions.table`: 28.5.0.6 ships 11.6.0.5, 28.5.0.7 ships 11.6.0.6); a major with no
recorded fix clamps. `OTP_VERSION` was the first choice and is not used, because an assembled release
does not carry that file. The container on 28.5.0.7 is configured exactly as before, the desktop on
28.5.0.6 clamps, and the clamp lifts itself the day the desktop pin moves, with nothing to remember.

**The clamp has three layers**, applied by `config/runtime.exs` before any application starts:

1. the `ssl` application's `protocol_version`, which every client that passes no `versions` option
   inherits: `:httpc` (and with it Bumblebee's and Tokenizers' downloads), Postgrex, WebSockex, a
   bare `:ssl.connect/3`;
2. Req's default options, which name `Trinity.TLS.Finch`, a Finch instance whose pool gives Mint
   `transport_opts: [versions: [:"tlsv1.2"]]`. This layer exists because Mint passes `versions`
   to `ssl` itself, from `ssl:versions()`'s `available` list, which ignores the first layer;
3. ReqLLM's own Finch pools, which its streaming requests use, with the same transport options.

A caller that needs transport options of its own (a private CA, for example) takes them from
`Trinity.TLS.req_options/1`, which keeps the clamp. A caller that passes `connect_options` directly is
refused by Req while the clamp is in force, because Req will not combine a named pool with connect
options: a loud failure rather than a quiet TLS 1.3 connection.

**The proof derives the clients from the release.** `test/trinity/tls_clamp_test.exs` reads the BEAM
import tables of every application in the release and lists every module that calls `ssl:connect`
and every module outside Mint that opens a Mint connection; each must be named in the test with the
layer that clamps it, and a named one no longer found fails as stale. It then reads the ClientHello
that each client path actually sends to a loopback listener (Req, ReqLLM with and without streaming,
`:httpc`, a bare `ssl:connect`, WebSockex, Postgrex) and fails on an offer of TLS 1.3 while the
runtime is affected. Its oracle for "affected" is the test runtime's own `OTP_VERSION`, read
independently of `Trinity.TLS`. On the FIPS leg, which runs the container's OTP, the same test
asserts the clamp is lifted.

**The desktop is green while the clamp is provably global, and red otherwise.** A dependency that
starts opening TLS connections the census does not name fails the gate until it is clamped or named.

**The canary.** `.github/workflows/otp-canary.yml` runs `scripts/otp_canary.sh probe` daily; when
Burrito serves the container's OTP for all three desktop targets it runs `flip` (`.tool-versions` and
the pin list), regenerates `VERSIONS.md` and `THIRD_PARTY_LICENSES.md` on the new OTP, and opens one
pull request per version.

## Consequences

- **The window.** Opened 2026-10-08. The desktop runs OTP 28.5.0.6, which carries CVE-2026-89422
  (mitigated by the clamp as the advisory prescribes) and CVE-2026-65634 (`asn1`, not mitigated: the
  clamp does not change how a certificate's OIDs are decoded). It closes when the canary's pull
  request is merged; the lift condition a stranger can check is the three URLs in
  `scripts/otp_canary.sh` returning 200 for 28.5.0.7. The owner merges it. The desktop is
  unreleased until slice 101, so during the window the exposure is development machines.
- On an affected runtime the `ssl` setting also limits TLS servers to TLS 1.2. The desktop serves
  plain HTTP on loopback, and the container is not affected, so no server Trinity runs today is
  changed by it.
- A server that accepts only TLS 1.3 fails to connect from the desktop during the window. That is a
  visible error, not a silent downgrade.
- Two residual paths are named rather than clamped. `Req.Finch`, Req's own pool, runs unclamped
  and is reached only by a request that names it or sets `finch: nil` without connect options; no
  code in the tree does. `ReqLLM.Streaming.HTTP2DuplexSession` opens Mint with no transport options
  (it is the transport of `ReqLLM.Bedrock.NovaSonic`); the census holds that no Trinity module
  reaches it.
- The gateways in slices 071 and 072 make TLS calls of their own. 072's Mattermost client passes
  `connect_options` for its CA file, which Req refuses beside the default pool; it must take its
  options from `Trinity.TLS.req_options/1` before it merges. Its WebSockex connection inherits the
  `ssl` setting.
- The pull request the canary opens starts no workflow (it is opened with `GITHUB_TOKEN`), and the
  repository must allow Actions to create pull requests. Both are stated in the workflow.
- The FIPS leg now runs the gate on the container's OTP, so the gate's two legs run two OTP patches
  of one major. Two checks had to learn that. `THIRD_PARTY_LICENSES.md` lists the OTP applications
  of the runtime that generated the bill, so on the container's OTP six of them (`asn1`, `compiler`,
  `public_key`, `ssh`, `ssl`, `stdlib`) carry newer versions: `mix trinity.third_party_licenses
  --check` accepts exactly that difference, and only when the runtime is the container's pin and not
  the desktop's. The census in `test/trinity/authority/selection_test.exs` counted outbound
  connections by application, and Req's pooled connections now belong to Trinity's supervisor; it
  leaves `Trinity.TLS.Finch` out, as it left `Req.Finch` out before. The desktop pin moving to the
  container's ends the first of these.
