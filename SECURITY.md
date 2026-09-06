<!-- SPDX-License-Identifier: Apache-2.0 -->
# Security policy

## Reporting a vulnerability

Email **security@scriptkittyos.com**. Please do not open a public issue for a suspected
vulnerability.

Include what you did, what happened, and what you expected. A proof of concept helps; a working
exploit is not required and is not expected.

You will get an acknowledgement. Trinity has a single maintainer today (see `MAINTAINERS.md`),
so response times are best effort and are not a service commitment.

## Scope

Trinity is a local-first desktop agent. The interesting surfaces are the permission gate, the
effect membrane, the receipt chain, the MCP server's authorization, and the sandbox.

## What Trinity does not claim

The BEAM is **not** an OS sandbox, and the plan says so in `docs/07-security-model.md` rather
than implying otherwise. The shell tool's child-kill guarantee is platform-dependent and is
stated per platform. A receipt signed by a key held in a file proves the chain was not altered
after the fact; it does not prove custody of the key.

## Supported versions

Pre-release. No version is supported yet; there has been no release.
