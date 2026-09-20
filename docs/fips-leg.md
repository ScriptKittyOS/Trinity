# The FIPS build leg

Slice 003. A second job in the gate workflow, `fips`, runs the whole gate on an OTP built from source with
`--enable-fips`, in FIPS mode, against the FIPS provider of a UBI9 container. It exists because slice 024 says
that in FIPS mode Trinity's receipts select ECDSA P-384 and never deny for want of a signer; until a build runs in
the mode, that is a sentence. The default legs (`gate`, `postgres`) stay exactly as they were.

Everything below was measured on 2026-09-20 on the image described here, unless a line says otherwise. Counts
name the command that produced them.

## What the leg runs

| Piece | Where | What it does |
|---|---|---|
| `ci/fips/Containerfile` | the image | UBI9 by digest; OTP 28.5.0.5 from the release tarball with `--enable-fips --with-ssl=/usr`; Elixir 1.20.4 from the release zip; both archives checked against SHA-256 digests pinned in the file; git, python3 with PyYAML, gcc and procps for the gate's own steps |
| `.github/workflows/fips-image.yml` | builds the image | On a change to `.tool-versions`, the Containerfile or the tag script, and on demand; pushes to `ghcr.io/scriptkittyos/trinity-fips` under the tag below; a tag already published is not rebuilt |
| `scripts/fips_image_tag.sh` | both workflows | The tag: sixteen hex digits of SHA-256 over `.tool-versions` and the Containerfile, so the builder and the puller cannot disagree |
| `.github/workflows/gate.yml`, jobs `fips-tag` and `fips` | the leg | Pulls the image, fetches and compiles dependencies with the mode off, asserts the mode, checks the mode-off listing, then runs `plan_check`, the DCO check and `mix gate`, all in the mode |
| `test/fips/mode_test.exs` | the suite | One untagged test binds `TRINITY_FIPS_LEG` to `crypto:info_fips/0` on every leg; three `:fips` tests (AC1 to AC3) run only where the leg declares itself |
| `scripts/crypto_supports.exs` | the listing | Prints `crypto:supports/0` one item per line, sorted, with the mode and library named first |
| `docs/fips-leg/supports-default.txt`, `supports-fips.txt`, `supports.diff` | the record | The two listings from the same image, mode off and mode on, and their `diff` |

## How the mode is entered

OTP reads the crypto application's `fips_mode` setting when the crypto NIF loads, and only if the application is
already loaded at that moment (`lib/crypto/src/crypto.erl`, `on_load/0`: an `undefined` setting is read as "the
application is not loaded" and the mode stays off with a warning). So the leg sets, for every `erl` the job runs:

```
ERL_AFLAGS="-crypto fips_mode true -eval application:load(crypto)"
```

`ERL_AFLAGS` is prepended to the command line, so the load runs before Elixir starts and before anything touches
`:crypto`. Measured on the image: with `ERL_FLAGS` (appended) carrying the same setting, `crypto:info_fips()`
answers `not_enabled` under `elixir -e`, because the NIF has loaded before the application; with `ERL_AFLAGS` it
answers `enabled`. Red Hat's own `OPENSSL_FORCE_FIPS_MODE=1` activates the provider for the `openssl` command but
leaves OTP's report at `not_enabled` on its own; it is not needed once OTP enters the mode itself, and the leg does
not set it. Entering and leaving the mode on a running node is not something the leg does: the setting is in the
environment, and no test toggles it.

`TRINITY_FIPS_LEG=1` is the leg's declaration. `test/test_helper.exs` includes the `:fips` tag under it and
excludes the tag elsewhere; `test/fips/mode_test.exs` asserts the runtime agrees with the declaration on every
leg, so a leg that failed to enter the mode is red rather than a quiet pass over excluded tests.

## The provider, and what is and is not claimed

The image's `fips.so` comes from the package `openssl-fips-provider-so-3.0.7-11.el9_8` (`rpm -qf
/usr/lib64/ossl-modules/fips.so`), whose description reads "a custom build of the OpenSSL FIPS module that has
been submitted to NIST for certification". `crypto:info/0` on the leg reports `fips_provider_buildinfo` as
`3.0.7-cda111b5812c30d4`. The distribution's library is `openssl-libs 3.5.8-1.el9_8`; the provider is the 3.0.7
module loaded beside it.

Red Hat's page, https://access.redhat.com/compliance/fips, read 2026-09-20, lists for Red Hat Enterprise Linux
9.8 the module "OpenSSL", version `3.0.7-395c1a240fbfffd8`, CMVP certificate #4857, status "Active". The version
string the image reports and the version string the page lists differ in their build hash. Trinity does not claim
they are the same binary, and does not claim a validation. What the leg establishes is narrower and exact: the
gate and the suite run with OTP in FIPS mode against the FIPS provider that this distribution ships and names,
with the algorithms the mode removes listed below. Whether a deployment's provider is a validated one is that
deployment's question, answered from the certificate and the running binary, not from this file.

## What the mode removes

`diff docs/fips-leg/supports-default.txt docs/fips-leg/supports-fips.txt` (the committed `supports.diff`):
51 entries removed (`grep -c '^<'`), one line changed (`fips_mode`). By category (`grep -c '^< <category>:'`):

| Category | Removed | Names |
|---|---|---|
| curves | 13 | brainpoolP256r1, brainpoolP256t1, brainpoolP320r1, brainpoolP320t1, brainpoolP384r1, brainpoolP384t1, brainpoolP512r1, brainpoolP512t1, ed25519, ed448, secp256k1, x25519, x448 |
| ciphers | 13 | blowfish_cbc, blowfish_cfb64, blowfish_ecb, blowfish_ofb64, chacha20, chacha20_poly1305, des_cbc, des_cfb, des_ecb, des_ede3_cbc, des_ede3_cfb, rc2_cbc, rc4 |
| hashs | 6 | blake2b, blake2s, md4, md5, ripemd160, sm3 |
| public_keys | 18 | eddh, eddsa, mldsa44, mldsa65, mldsa87, the twelve slh_dsa variants, srp |
| macs, rsa_opts | 0 | |

Curves that remain: prime256v1, secp224r1, secp256r1, secp384r1, secp521r1. Measured beside the listing, with a
fixed RFC 8032 key: `crypto:sign/4` and `crypto:verify/5` with `eddsa` raise `{notsup, {"pkey.c", 235},
"Unsupported algorithm in FIPS mode"}`; `crypto:generate_key(eddsa, ed25519)` fails earlier and differently
(`{error, {"evp.c", 264}, "Can't make context"}`); `ecdsa` on `secp384r1` with `sha384` signs (a 103-byte DER
signature) and verifies; `md5` raises `notsup`; `sha`, HMAC-SHA-256 and `strong_rand_bytes` work.

For slice 024: this OTP, built against OpenSSL 3.5.8, lists `mldsa44`, `mldsa65` and `mldsa87` with the mode off,
so amendment 6 of that slice is measurable on this image in non-FIPS mode. The 024 slice text assumed UBI9's
OpenSSL was a 3.0 line; as of 9.8 it is not.

## Findings

1. **Hex cannot reach hex.pm in the mode.** Hex 2.5.1 hardcodes `[:"tlsv1.2", :"tlsv1.1", :tlsv1]`
   (`lib/hex/http/ssl.ex`, `@default_versions`) and ssl in FIPS mode refuses the set:
   `{options, {insufficient_crypto_support, {'tlsv1.1', {versions, ['tlsv1.2', 'tlsv1.1', tlsv1]}}}}`. So
   `mix deps.get` runs with the mode off in the leg, and the gate's `hex.audit` step runs with `ERL_AFLAGS`
   cleared (`mix.exs`), which on the default legs changes nothing. `mix deps.audit` (mix_audit) works in the
   mode. Owner: Hex, upstream; the fetch is not a property the leg measures.
2. **OTP's TLS 1.3 client fails a HelloRetryRequest, and the mode makes that common.** ssl 11.6.0.4: a server
   that answers the client's first key share with a HelloRetryRequest gets a client alert, "Failed to assert
   middlebox server message" from state `hello_retry_middlebox_assert`. Measured with the mode off by forcing
   `secp521r1` first: the same alert, so the fault is the retry handling, not the mode. The mode exposes it
   because `x25519` leaves and `secp521r1` leads the default group order (`ssl:groups/0` in the mode:
   secp521r1, secp384r1, secp256r1, the ML-KEM hybrids, the ffdhe groups), and `release-assets.githubusercontent.com`
   and `repo.hex.pm` both retry. `github.com` and `api.github.com` complete. Upstream: erlang/otp issue #8470
   (labelled not a bug, stalled), earlier #7586. Two workarounds measured against both hosts in the mode:
   `middlebox_comp_mode: false`, or `supported_groups: [:secp256r1, :secp384r1, :secp521r1]`. In the leg the
   dependency compile runs with the mode off, because `rustler_precompiled` downloads mdex's NIF from the first
   host at compile time. **Owner in the tree: slice 002 (the TLS floor)**, which sets the group order for Trinity's
   own clients (Req, req_llm, the web tools); a FIPS deployment that fetches from such hosts hits this at run time.
3. **The provider's version string is not the page's.** See the section above; owner: the deployment's assessor,
   named in `docs/09-standards-register.md`.

## Reds on the leg, by test name

Filled at G3 from the leg's first run: every red is fixed here when the fault is the test's, or listed with the
slice that owns it when the fault is a removed algorithm. No skip tag exists for this.

## Reproducing the image and the leg on a machine

```
docker build --build-arg OTP_VERSION=28.5.0.5 --build-arg ELIXIR_VERSION=1.20.4 \
  -t trinity-fips:local -f ci/fips/Containerfile ci/fips
docker run --rm -v "$PWD:/work" -w /work \
  -e MIX_ENV=test -e TRINITY_DB=sqlite -e TRINITY_FIPS_LEG=1 trinity-fips:local bash -c '
    git config --global --add safe.directory /work
    ERL_AFLAGS="-eval application:load(crypto)" mix deps.get
    ERL_AFLAGS="-eval application:load(crypto)" mix deps.compile
    export ERL_AFLAGS="-crypto fips_mode true -eval application:load(crypto)"
    mix gate'
```

On the machine this was written on (32 cores) the OTP build step took 41 s; the runner's time is in the slice's
NOTES.md once the first ten runs exist.
