# Private deployment through an existing VPN

The installer owns the internal HTTPS load balancer, reserved private IP,
serverless NEG, regional Cloud Armor source allowlist, and Cloud Run ingress.
The customer owns VPN connectivity, routes, DNS, and the TLS certificate. This
mode is implemented and mock-tested; a deployment on the customer's private
network is required to validate it end to end.

Traffic flows from VPN clients to the internal HTTPS frontend, through Cloud
Armor, and into Cloud Run. Only configured source IPv4 CIDRs are allowed; other
sources receive HTTP 403. The listener is HTTPS-only on port 443, with TLS 1.2
or newer. No public load balancer or HTTP listener is created.

Cloud Run uses internal ingress and disables its default run.app URL so that
internal callers cannot bypass the load balancer allowlist through that URL.
Private mode disables the Cloud Run invoker IAM check: browsers authenticate
with OpsRabbit itself after passing network restrictions. It does not grant an
allUsers IAM binding. This is unsuitable for organizations whose policies require
the Cloud Run invoker IAM check; use a separately designed identity-aware entry
point in that case. OpsRabbit authentication, signup policy, and authorization
still need configuration and testing.

## Ownership across installers

| Responsibility | AWS | Azure | GCP |
|---|---|---|---|
| Select exposure | `public_access_enabled` | `network_mode` | `network_mode` |
| Private application entry | Installer-managed internal ALB | Private ACI IP with customer gateway, or internal ACA environment | Installer-managed internal HTTPS load balancer |
| Customer network reuse | Existing VPC/subnets | Existing subnets and private DNS zones | `create_vpc=false`, existing VPC/subnet and optional existing proxy subnet |
| VPN, routing and application DNS | Customer | Customer | Customer |
| Source restriction | ALB security group CIDR | Customer network policy | Regional Cloud Armor CIDRs |

This follows the same ownership boundary, using each cloud's networking
primitives. GCP firewall rules do not filter serverless NEG backend traffic,
so the load balancer uses Cloud Armor for the source allowlist. This installer
does not provision VPN gateways, routing VMs, VPN enrollment keys, or client
access policies. Those remain in the customer's network configuration,
regardless of VPN vendor. An existing customer VPC/subnet/proxy subnet is read
and referenced, never imported or deleted by this installer. Private services
access for SQL/Filestore is installer-managed as described in `network.tf`.
The current installer creates that connection and allocation; it does not offer
an option to reuse a customer-owned private-services connection. Use a VPC
without an existing `servicenetworking.googleapis.com` connection, or resolve
that ownership separately before applying. Do not import a shared customer
connection into this stack: destroying the stack would attempt to delete it.

References: [AWS networking](https://github.com/Ops-Rabbit/opsrabbit-aws-deployment/tree/main/terraform),
[Azure installer](https://github.com/Ops-Rabbit/opsrabbit-azure-deployment).

## Customer inputs

Copy the network settings from `private.tfvars.example` into your environment's
inputs. Both the network and all selected subnets must be in the deployment
project; Shared VPC across projects is not supported by this configuration.

- Existing VPN/private routing into the selected VPC, including return routes.
  The allowlist must contain the client or translated source ranges the load
  balancer actually sees, not an assumed VPN gateway public IP. Routed access
  from other networks alone does not authorize their sources.
- A regular subnet in the Cloud Run region, used for Direct VPC egress and the
  load balancer frontend. Do not use the proxy-only subnet for this purpose.
- An existing ACTIVE `REGIONAL_MANAGED_PROXY` subnet in that VPC/region, or an
  unused IPv4 /26-or-larger range for the installer to create one. Reuse an
  existing regional proxy subnet if present; only one active proxy subnet of
  that purpose can be used per VPC/region. Check that new ranges do not overlap
  application, private-service-access, or VPN routes. The pinned provider's
  subnet data source cannot inspect purpose/role; explicitly verify them:

  ```sh
  gcloud compute networks subnets describe PROXY_SUBNET \
    --project=PROJECT_ID --region=REGION \
    --format='yaml(network,region,purpose,role,ipCidrRange)'
  ```

- Existing **regional Compute SSL certificates** in the same project/region
  covering `application_origin`, with a trust chain accepted by VPN users.
  Global certificates and Certificate Manager certificate-map references are
  not accepted by this interface. Certificate private keys are not Terraform
  inputs. Customers own certificate issuance and renewal.
- Private DNS resolving the application hostname to `private_load_balancer_ip`,
  including DNS forwarding/resolution for VPN clients. The installer outputs the
  IP; it does not own or change the customer's DNS zone.

`allow_global_access` defaults to true so clients connected through another
region can access the regional frontend. This does not make the IP public or
create any VPN routes. Set false when intentionally requiring regional access.
Private mode also works with `create_vpc=true` and `proxy_subnet_cidr`, but the
customer must connect their VPN/network to that new VPC before use.

## Rollout and verification

1. Prepare the network, certificate, and input values. Bootstrap infrastructure
   with `application_enabled=false`, import images, and initialize/test Filestore
   as documented in README. Private inputs are required even during bootstrap;
   the load balancer is created with the application, not during bootstrap.
2. Enable the application, review and apply the plan, then create/update the
   private DNS record using `private_load_balancer_ip`.
3. From an allowed VPN client, verify DNS, TLS hostname/trust, the login page,
   `/api/health`, authentication redirects/cookies, and product workflows.
4. From a routed but non-allowlisted source, expect 403. Confirm spoofing an
   X-Forwarded-For header does not bypass the source allowlist.
5. Disconnect the VPN and confirm the private frontend is unreachable. Check the
   previous run.app URLs from both outside and inside the VPC: they must not
   serve the application. Confirm no separately managed domain mapping or other
   ingress path has been introduced.

Changing an existing public deployment to private intentionally removes direct
public access and creates a new entry point. Plan a cutover with working VPN,
DNS, and TLS first. This change does not require replacing SQL or Filestore.
No live private cutover is performed just by adding this code.

The internal load balancer and Cloud Armor incur additional charges. The matching
google-beta 6.50.0 provider is used for Cloud Run default-URL control and regional
backend security-policy attachment; both providers are mocked in offline tests.

References:
- https://docs.cloud.google.com/load-balancing/docs/l7-internal/setting-up-l7-internal-serverless
- https://docs.cloud.google.com/run/docs/securing/ingress
- https://docs.cloud.google.com/armor/docs/security-policy-overview
