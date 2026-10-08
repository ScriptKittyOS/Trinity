<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# The headless image: how it is built, and what is checked about it

For an operator deploying Trinity as a container, and for an assessor who wants to know what the
image is and how the claims about it are checked. Every check named here is a command in this
repository; run it and read its exit code rather than taking this page's word for it.

## What this is not

**The image is not in Iron Bank.** It is built to Iron Bank's published rules and the submission is
laid out the way their pipeline reads it, but it has not been submitted, reviewed or accepted.
**Nothing here is an authority to operate, a STIG compliance determination for a host, or a FedRAMP
authorization.** The STIG applicability statement below is a statement about one image; whether a
system that runs it is compliant is decided for that system by whoever authorizes it.

## One recipe, two artifacts

`ci/ironbank/Dockerfile` is the only recipe for the headless image. It is built two ways:

| Artifact | Bases | Where the inputs come from |
|---|---|---|
| The image this project publishes | `ci/headless/bases.env`: Red Hat's UBI9 and UBI9 micro, **pinned by digest** | `scripts/headless_image.sh` downloads each resource in `ci/ironbank/hardening_manifest.yaml` and checks its digest |
| An Iron Bank build | Their registry and the tags in `hardening_manifest.yaml`, supplied as `BASE_REGISTRY`, `BASE_IMAGE`, `BASE_TAG`, `BUILDER_IMAGE`, `BUILDER_TAG` | Their pipeline downloads the same resources and checks the same digests |

Both start from the same bytes: the digests in `bases.env` are the ones Iron Bank's own UBI 9.8
images declare as their sources.

```
scripts/headless_image.sh build trinity-headless:local
docker run --rm -p 4000:4000 -v trinity-data:/data \
  -e TRINITY_MCP_SERVER_TOKEN=<token> trinity-headless:local
```

The build labels the image with the manifest's OCI labels and `org.opencontainers.image.source`,
and with `org.opencontainers.image.revision`, the commit, only when no tracked file differs from
that commit; the labels go on the build command, because Iron Bank's lint refuses `LABEL` in the
Dockerfile.

The build reaches no network. Every input that is not a UBI package (the OTP and Elixir sources,
Hex and rebar3, the asset tools, and today's precompiled native pieces) is a file in the build
context, named in the manifest with its SHA-256 or SHA-512. dnf is the one exception, and reaches
only UBI's repositories, which Iron Bank proxies. `scripts/headless_image.sh` is what reaches the
network, playing the part of Iron Bank's prebuild step; it is not part of the submission.

## What is in the image

* **UBI9 micro**, with the two libraries the release links that micro lacks (`libstdc++` and
  `openssl-libs`, which brings the CA trust store with it as `ca-certificates`), installed with
  `dnf --installroot` so the image's rpm database stays true to what is on disk. No package
  manager, compiler or shell history.
* **Erlang/OTP 28**, built from source with FIPS support against that OpenSSL
  (`docs/fips-leg.md`).
* **The Trinity release**, under `/opt/trinity`, owned by root and not writable at run time.

It runs as UID 10001. The only path it writes is `/data` (the data directory, a volume) and `/tmp`;
it runs with a read-only root filesystem, all capabilities dropped and no privilege escalation.
**Erlang distribution is off** (`RELEASE_DISTRIBUTION=none`) and **the image carries no
distribution cookie**: each container gets its own at start (`ci/ironbank/scripts/entrypoint.sh`).
The image listens on one port, 4000.

## The checks

All of them read the **built image** or the files, never a description of either. The workflow
`.github/workflows/headless-image.yml` runs every one on each change to an input of the image,
daily, and on demand, and uploads the scan, the findings and the STIG results as evidence.

| What | Command | Fails when |
|---|---|---|
| The submission tree and the base pins | `mix trinity.ironbank.lint` | a `FROM` names a registry, or the published build resolves a base without a digest; the Dockerfile or a submission script mentions `curl`, `wget` or a URL, or uses `ADD`; a copied file is not a declared resource; a `chmod` makes something world-writable or SUID; `--nogpgcheck`; `/etc/passwd` is written; the layout or the manifest departs from Iron Bank's |
| The image's user and layers | `mix trinity.image.inspect IMAGE` | the image runs as root or below UID 1000; a layer it adds carries a package manager, a build tool, a build-time library, shell history, documentation, a certificate, a SUID or SGID file, or a world-writable path; `/etc/passwd` changed mode; anything in the image holds a private key, a keystore or a distribution cookie |
| Vulnerabilities | grype, then `mix trinity.image.findings --scan grype.json` | a High or Critical finding has no row in `ci/headless/justifications.yaml`, or a row justifies a finding the scan no longer reports |
| STIG applicability | `scripts/stig_scan.sh IMAGE OUT`, then `mix trinity.image.stig --results OUT/stig-results.xml` | a rule of the DISA STIG profile has no disposition, or a disposition is kept for a rule that no longer needs one |

When every check passes, on `main`, on a `v*` tag or on demand, the workflow's `publish` job
pushes that same image by digest, signs it with the project's held key, attaches its build
provenance, SBOM and AI-BOM, and verifies the result the way a consumer would.
`image-verify.md` is that consumer's command sequence, and states the SLSA level claimed and why.

### Allowances, and why there are any

Some findings of the layer check are the image working as intended, and
`ci/headless/image_allowances.yaml` allows them, each with its reason: the operating system's CA
trust store (which the runtime verifies model providers against), a CA bundle a dependency carries,
and build-time libraries the release currently carries as applications. **One is a private key:**
the `jose` library embeds a published RSA test key pair that its capability probe signs with. It
protects nothing, but Iron Bank's rule names test material, so it is listed for review rather than
hidden; its allowance names the exact file and the SHA-256 of the key block, so any other key fails.
Only those four kinds can be allowed, and an allowance that no longer allows anything fails as
stale.

### The scanner, and what it cannot see

The scan is grype, chosen by measuring it against Trivy on this project's images: both run with no
network at scan time and no token, both read UBI's rpm database, and **only grype identifies the
Erlang/OTP runtime** inside a release and matches advisories against it. Iron Bank's own CVE scan is
Anchore's, whose engine is grype. Neither scanner inventories the Hex packages inside a release;
those are covered by `mix deps.audit` over `mix.lock` in the quality gate.

### Justifications are keyed the way Iron Bank's tracker keys a finding

A row in `ci/headless/justifications.yaml` names the finding, the package as `name-version`, and the
package path (empty for a package the OS database reports), so it covers one version of one package
and an upgrade retires it. A justification states facts someone else can check; a finding with a fix
available is fixed rather than justified.

### The STIG applicability statement

`docs/regulated/stig-applicability.md` is **generated**: OpenSCAP evaluates the image's root
filesystem against the DISA STIG profile for RHEL 9 from the SCAP Security Guide (the profile and
datastream Iron Bank's pipeline uses for a UBI9 image), and `mix trinity.image.stig` gives every
selected rule a disposition. A rule that passes is met; a rule OpenSCAP finds inapplicable is not
applicable, with the rule's own applicability condition as the reason (most STIG rules are about a
machine with a kernel, a boot loader and services, which a container image is not); anything else
needs a row in `ci/headless/stig_dispositions.yaml` saying how the image meets it, why it does not
apply, or why it is the deployment's. The file carries the image digest, the guide's version and the
commands that produced it.

## The Iron Bank submission

`ci/ironbank/` is laid out as the root of an Iron Bank project, file for file: `Dockerfile`,
`hardening_manifest.yaml`, `LICENSE`, `README.md` and `scripts/`. Labels live in the manifest, never
in the Dockerfile. There is no configuration directory: the image takes its configuration from the
environment.

What stands between this tree and a submission is listed in `ci/headless/submission_holds.yaml`,
each with an owner and a condition for lifting it, and `mix trinity.ironbank.lint --submission`
refuses while any remains: the Trinity source archive and the Hex dependency tree have no published,
checksummed URL yet, and the maintainer has no repo1 account. The submission itself, and the review
of it against repo1's intake requirements, are the maintainer's.

## Known gaps, stated

* **The OTP runtime has open advisories** fixed in OTP 28.5.0.7, including a Critical one in `ssl`.
  They are not justified, so the vulnerability check fails on the image until the toolchain moves.
* **The release still carries the local embedder** (`exla` and the XLA library, `tokenizers`) and
  some build-time libraries. Removing them from the regulated image is a change to what the release
  contains, made separately; it removes resources from the manifest and rows from the allowances,
  and changes nothing in how the image is checked.
