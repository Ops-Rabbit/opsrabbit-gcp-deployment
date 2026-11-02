# OpenSandbox chart source

These readable chart directories were extracted from packages generated with
`helm package` from upstream OpenSandbox
commit `531700ca18a7fa5fab6a2f25d6dc68a76eddab12`, release 1.1.1.
Source: https://github.com/opensandbox-group/OpenSandbox/tree/531700ca18a7fa5fab6a2f25d6dc68a76eddab12/manifests/charts

Upstream chart source carries Apache-2.0 notices. No chart templates were modified.
The installer supplies runtime overrides separately. `source-sha256.json` pins
every extracted chart file; tests reject changed, missing or extra source files.
The archive hashes below record the original packages, which are not required
at runtime. Keep the base, controller,
gateway and server versions aligned. Optional fast-sandbox components are disabled.

| Package | SHA-256 |
| --- | --- |
| base-1.1.1.tgz | 724bf40381f31288356cf7299d4a366d5aee22394b461ae730752a8d0b56eabd |
| opensandbox-controller-1.1.1.tgz | 6fe48f6d968615af076d612ba01a9ac5c09d9079cfd43210c876d6c47181e8a6 |
| ingress-gateway-1.1.1.tgz | f6b44eb03fdee50a419eeaf926871022da7f1241cfb3ccee0aeda160bd8e05f3 |
| opensandbox-server-1.1.1.tgz | b2009d9fbaa5c9fcbce58de216c8d8067bb2e4c15048765673a29c0cf1dbc33e |

Release status: integration is under development. Packaging and Terraform
validation do not establish customer readiness or Autopilot compatibility.
