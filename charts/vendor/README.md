# OpenSandbox chart source

These readable chart directories were extracted from packages generated with
`helm package` from upstream OpenSandbox
commit `db708c218771a8d311356f0e96552c15df6e097a`, release 1.2.1.
Source: https://github.com/opensandbox-group/OpenSandbox/tree/db708c218771a8d311356f0e96552c15df6e097a/manifests/charts

Upstream chart source carries Apache-2.0 notices. No chart templates were modified.
The installer supplies runtime overrides separately. `source-sha256.json` pins
every extracted chart file; tests reject changed, missing or extra source files.
The archive hashes below record the original packages, which are not required
at runtime. Keep the base, controller,
gateway and server versions aligned. Optional fast-sandbox components are disabled.

| Package | SHA-256 |
| --- | --- |
| base-1.2.1.tgz | 0460b2571788adae499f65f60c6b4b0eb0c31cddcc5dc178b76e758229554583 |
| opensandbox-controller-1.2.1.tgz | a6faa7add1375f63520775d4b99f5db38d3c8c854e7b90326d5fcda6b5550535 |
| ingress-gateway-1.2.1.tgz | 9259ab70c5a2c3d9323e659e67a288af130fc196ad50a869c21c9bb44826aa95 |
| opensandbox-server-1.2.1.tgz | ba5995c3b37d97dcc59c85b671525efd74ed10deb747b53d6c348aff8bb55b38 |

Release status: integration is under development. Packaging and Terraform
validation do not establish customer readiness or Autopilot compatibility.
