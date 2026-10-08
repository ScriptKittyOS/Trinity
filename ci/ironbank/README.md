<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Trinity headless

Trinity is a personal AI agent built on Elixir and OTP. This image runs it headless: an MCP
server on `/mcp` and Trinity's web interface, on one port, with no desktop shell. It is
customer-controlled software. There is no Trinity-operated service behind it; the agent, its
memory and its signed record of every governed action live in the data volume you give it.

This image is a candidate for Iron Bank. **It has not been accepted there, and nothing here claims
an authority to operate, a STIG compliance determination or a FedRAMP authorization.** The
evidence this project produces about the image (its layer assertions, vulnerability scan with
justifications, and STIG applicability statement) is described in the project's
`docs/regulated/headless-image.md`.

## What is in the image

* Erlang/OTP 28, built from source with FIPS support, linked against the base image's OpenSSL.
* The Trinity release, under `/opt/trinity`, owned by root and not writable by the runtime user.
* The UBI9 micro base and the two libraries the release links that micro lacks (`libstdc++`,
  `openssl-libs`). No package manager, compiler or shell history.

It runs as UID 10001. The only writable path it needs is `/data`, its data directory; `/tmp` is
used for the release's runtime files. Erlang distribution is off (`RELEASE_DISTRIBUTION=none`), so
the container listens on one port, 4000, and nothing else.

## Running it on Kubernetes

The MCP endpoint requires a bearer token on every request. Give it one through a Secret; without
one, Trinity generates a token into the data volume on first start (`/data/trinity/mcp-server-token`).
`SECRET_KEY_BASE` signs the web interface's cookies; without it, a new one is generated on every
start and signed cookies do not survive a restart.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: trinity
stringData:
  mcp-server-token: "<a long random value>"
  secret-key-base: "<at least 64 random bytes, base64>"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: trinity-data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trinity
spec:
  replicas: 1
  selector:
    matchLabels: {app: trinity}
  template:
    metadata:
      labels: {app: trinity}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: trinity
          image: registry1.dso.mil/ironbank/opensource/scriptkittyos/trinity-headless:0.1.0
          ports:
            - containerPort: 4000
          env:
            - name: TRINITY_MCP_SERVER_TOKEN
              valueFrom:
                secretKeyRef: {name: trinity, key: mcp-server-token}
            - name: SECRET_KEY_BASE
              valueFrom:
                secretKeyRef: {name: trinity, key: secret-key-base}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          volumeMounts:
            - {name: data, mountPath: /data}
            - {name: tmp, mountPath: /tmp}
          readinessProbe:
            tcpSocket: {port: 4000}
          livenessProbe:
            tcpSocket: {port: 4000}
            initialDelaySeconds: 30
          resources:
            requests: {cpu: "500m", memory: "1Gi"}
            limits: {memory: "4Gi"}
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: trinity-data}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: trinity
spec:
  selector: {app: trinity}
  ports:
    - {port: 4000, targetPort: 4000}
```

One replica: this image keeps its state in SQLite in the data volume, and two pods must not share
one.

Model providers are configured through the environment. The source repository's
`docs/regulated/` describes the regulated profile and the controls it puts on model endpoints.

## Resource requirements

Measured on 2026-10-08, on one host, in two runs of two builds of this image: the container used
**288 MiB and 330 MiB** of memory idle, about 20 seconds after start, before any session
(`docker stats`). The image is 655 MB. Memory grows with the number and length of conversations,
and with the local embedding model if a deployment uses it, which loads on first use; neither was
measured under load. The request and limit in the example above are a starting point with that
headroom, not a measured requirement; size them to the workload. The data volume holds Trinity's
SQLite databases and its signed receipt chain, both of which grow with use; 5 GiB is a starting
point.

One process runs in the container. It needs no capabilities, no privilege escalation and no
writable root filesystem.

## References

* Source and documentation: <https://github.com/ScriptKittyOS/Trinity>
* The MCP server: `docs/mcp-server.md` in the source repository
* The regulated deployment pack: `docs/regulated/README.md` in the source repository
* Security reports: <security@scriptkittyos.com>, as `SECURITY.md` in the source repository says
