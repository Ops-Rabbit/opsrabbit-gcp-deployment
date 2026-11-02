# SKILLS-143: upstream permissions decision

Inspected 2026-11-02, upstream source commit
`531700ca18a7fa5fab6a2f25d6dc68a76eddab12` (OpenSandbox 1.1.1).

The controller chart's `templates/clusterrole.yaml` grants cluster-wide Pod
management and Secret get/list/watch. Its ClusterRoleBinding binds those
permissions to the controller. The server chart's `templates/rbac.yaml` grants
cluster-wide Pod, service, configuration, Secret, PVC and custom-resource
operations. A separate workload namespace does not restrict those grants.

The packaged charts preserve upstream permissions. Dedicated-cluster support
therefore trusts these components with cluster-wide access; it does not claim
namespace-restricted RBAC. Shared-cluster support requires separate design and
acceptance before it can be enabled.

Owner clarification on 2026-11-02 limits immediate delivery to dedicated Standard
and Autopilot installations. Shared GKE is a future requirement. Keep upstream
permissions explicit, separate cluster prerequisites from application releases,
and avoid claiming isolation based on namespaces alone. A future shared mode must
preserve platform-owned resources and discover existing CRD/controller ownership.
Any restriction must be verified against controller watches and
server operations; replacing ClusterRoles with Roles without runtime validation
is insufficient.

Source inspection confirms the controller calls `ctrl.NewManager` without cache
namespace restrictions. Server provider code also has all-namespace workload
lookup paths. These are documented prerequisites for future shared support;
no shared cluster is required for this delivery.

Autopilot rejected the upstream workspace-only runtime's SYS_ADMIN and privileged
IPv6 init requirements. The owner explicitly chose to preserve workspace-only
isolation and expand runtime work. The installer now selects a narrowly patched
Kubernetes server profile, non-root workload identity, no workload capabilities,
explicit Unconfined AppArmor/seccomp, and IPv4-only networking. The network
sidecar retains NET_ADMIN. This is not a namespace-restricted distribution and
does not reduce the upstream controller/server RBAC.

A disposable Autopilot feasibility cluster is being used for live admission and
execution checks. A basic Bubblewrap restricted filesystem probe passed; that
does not establish full product or browser compatibility. Existing Standard proof
also does not validate this installer. Record final acceptance separately before
claiming customer readiness.
