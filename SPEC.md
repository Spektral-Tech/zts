# ZTS — Technical Specification

**Status:** Draft 0.1.2 (pre-release)  
**Implementation reference:** Go core (`cmd/zts`) and `zts.sh` v0.2 (bash essentials), in parity  
**Scope of this document:** target architecture plus an explicit implementation-status boundary.

RFC 2119-style terms **MUST**, **SHOULD**, and **MAY** indicate normative requirements.

---

## 1. Purpose

ZTS is a declarative network substrate for isolated workloads.

A managed workload begins without connectivity. ZTS observes runtime identity and current kernel state, compares them to a desired manifest, and materializes only the network paths authorized for that workload.

ZTS is designed so that an arbitrary unmodified container image can participate without an SDK, sidecar, injected agent, custom entrypoint, or application-level integration.

---

## 2. Architectural boundary

ZTS separates four concerns:

```text
runtime inventory
    identifies workload/netns
            |
            v
desired-state manifest
    declares relationships/capabilities
            |
            v
reconciler
    computes drift and materialization
            |
            v
Linux dataplane
    netns / veth / routes / nftables / WireGuard
            |
            +----> optional L7 proxy
```

The runtime (Docker in the reference implementation) is an inventory source, not the ZTS source of network truth.

The manifest is the desired state.

The Linux kernel is the realized state.

---

## 3. Trust model

### 3.1 Trusted

The reference model trusts:

- the host kernel;
- root or the privileged actor applying ZTS state;
- the manifest source and signing/approval process, when present;
- private keys and proxy credentials within their designated trust boundaries.

### 3.2 Untrusted

ZTS MUST NOT require trust in:

- application code inside a workload;
- the container image behaving cooperatively;
- workload source IP alone as proof of identity;
- ambient LAN membership;
- the presence of a workload inside a Docker bridge;
- a transport carrier to enforce per-workload authorization.

### 3.3 Consequence of host compromise

The base architecture does **not** protect ZTS from a malicious host root/kernel. A privileged host administrator can alter namespaces, routes, firewall rules, processes, and memory.

Stronger separation requires moving sensitive authority to another VM/host/HSM/KMS boundary.

---

## 4. Core invariants

### ZTS-INV-001 — No ambient network

A managed workload MUST be created without ambient host/LAN/internet connectivity.

For Docker, the reference binding is `--network none`.

### ZTS-INV-002 — Unmodified workload

ZTS MUST NOT require modifications to the container image or application.

### ZTS-INV-003 — Runtime read-only integration

The reconciler SHOULD treat the container runtime as read-only inventory.

It SHOULD NOT require `docker network connect`, container restart, runtime network mutation, or image changes.

### ZTS-INV-004 — Fail closed

Absence or removal of ZTS materialized state MUST result in less connectivity, never more connectivity.

### ZTS-INV-005 — Identity is provenance, not authorization

A workload identity MUST only identify the source context used by policy. It MUST NOT imply unrestricted reachability.

### ZTS-INV-006 — Declarative desired state

A manifest MUST describe logical resources, relationships, profiles, grants, and transports. It SHOULD NOT expose provider-specific interface names, nftables chains, routing-table numbers, or veth commands as user-facing intent.

### ZTS-INV-007 — Native dataplane

Once materialized, ordinary packet forwarding SHOULD be performed by native kernel/network components rather than a custom always-on ZTS daemon.

### ZTS-INV-008 — No mandatory TLS interception

ZTS MUST NOT require MITM or counterfeit server identity. Direct TLS MUST remain end-to-end when policy chooses a real destination.

### ZTS-INV-009 — Carrier separation

A carrier such as Tailscale or an outer WireGuard link MAY transport ZTS traffic but MUST NOT be the sole definition of workload authorization.

### ZTS-INV-010 — Explicit L7 mediation

Application-layer proxies MAY apply additional policy where required. Workloads that do not require L7 mediation SHOULD be routed without it.

---

## 5. Runtime discovery

A runtime adapter discovers candidate workloads.

For Docker, a managed container is selected by one label:

```text
zts.profile=<manifest profile>          required
zts.identity=<stable logical identity>  optional; defaults to the container name
```

The runtime is read through the Engine API on its Unix socket. No CLI is required.

The adapter MUST obtain at least:

- container/runtime identifier;
- PID or network namespace handle;
- logical identity;
- profile/binding metadata;
- lifecycle state.

The adapter MUST NOT assume a stable PID across restarts.

A restarted workload with a new network namespace is drift and MUST be re-materialized.

---

## 6. Desired-state model

The manifest describes logical desired state.

### 6.1 Substrate

```yaml
substrate:
  namespace: zts
  pool: 100.64.0.0/10
```

`namespace` names the local Linux namespace used by the reference provider.

`pool` is address space available to the provider. Address allocation is an implementation detail and MUST NOT be treated as workload identity.

`resolvers` (optional, default `[1.1.1.1, 9.9.9.9]`) are the upstream resolvers used for name-based resources.

### 6.2 Profiles

A profile defines desired reachability for a class of workload.

```yaml
profiles:
  development:
    allow:
      - to: accounting-db
        protocol: tcp
        ports: [5432]

      - to: internet
        via: sandbox-egress
        protocol: tcp
        ports: [80, 443]
```

The profile expresses relationships, not Linux commands.

### 6.3 Resources

A resource is a logical destination resolvable by the provider.

Resource forms in v0.2:

```yaml
resources:
  accounting-db:
    workload: accounting-db          # a managed workload on this host

  internet:
    cidrs: [0.0.0.0/0]               # IPv4 address space

  github:
    names: [github.com, "*.github.com"]   # DNS names; a name covers its subdomains; "*" is any name
```

**Names without a proxy.** A workload's only resolver is its ZTS gateway. Per profile, that resolver answers only the names its profile declares; any other name is NXDOMAIN (absence, not rejection). Each answer feeds the resolved addresses into a kernel set that the forwarding policy references. The application sees ordinary DNS and ordinary TLS to the real peer. No proxy, no CA, no environment variable, no SNI inspection.

Consequences:

- A raw address that was never resolved for a declared name has no path.
- All name-based relations of a profile MUST use the same transport.
- Addresses inside private, link-local or multicast space resolved for a name are dropped by the host transport guard (see §8.5), which closes DNS rebinding.

Future resource resolvers MAY support service discovery, remote workload identities, dynamic inventories, capability sets, or external provider APIs.

### 6.4 Transports

A transport is a permitted carrier/next-hop implementation.

Transport types in v0.2:

```yaml
transports:
  host:
    type: host              # leave through this host's default route (NAT)
    allow_private: false    # optional; lifts the private-space guard

  sandbox-egress:
    type: wireguard
    address: 10.255.255.2/32
    private_key_file: /etc/zts/sandbox-egress.key
    peer:
      public_key: ...
      endpoint: 192.0.2.10:51820
      allowed_ips:
        - 0.0.0.0/0
```

A transport is not a workload permission by itself. Profiles/grants determine which workloads may use it.

`type: host` is the default of a first install: it requires nothing beyond the kernel. WireGuard is optional and only needed when a `wireguard` transport is declared.

---

## 7. Reconciliation semantics

The reconciler operates conceptually as:

```text
D = desired(manifest, runtime inventory)
A = actual(kernel state)
P = diff(A, D)
apply(P)
verify(actual == desired)
```

### 7.1 Properties

Reconciliation SHOULD be:

- idempotent;
- deterministic for identical inputs;
- fail-closed on partial failure;
- explicit about destructive operations;
- capable of garbage-collecting orphaned provider state;
- safe against concurrent invocations or guarded by a lock.

### 7.2 Plan

`plan` SHOULD report intended changes without mutation.

### 7.3 Apply

`apply` MUST mutate only ZTS-owned state required to converge desired state.

### 7.4 Status

`status` SHOULD report workload bindings, unresolved resources, drift, transports, and materialization health.

### 7.5 Destroy

`destroy` MUST remove ZTS-owned network state without deleting or modifying runtime workloads.

After destruction, a correctly-created Docker workload returns to `--network none` behavior.

### 7.6 Up (controller)

`up` applies, then reconciles again on every container `start` and `die` event, and when the manifest file changes (polled every two seconds; an invalid manifest is reported and the previous state stays applied). The controller is never in the packet path: stopping it leaves kernel state, routes and already-resolved names in place. In the Go core the per-profile resolvers are detached processes and outlive the controller; in the bash essentials they are children of the controller.

---

## 8. Linux provider

### 8.1 Workload attachment

For a managed workload, the provider SHOULD:

1. discover its network namespace;
2. create a veth pair;
3. move the workload end into the workload namespace;
4. attach the substrate end to the ZTS namespace/provider topology;
5. configure addresses and routes;
6. install anti-spoofing and authorization rules;
7. verify reachability matches desired state.

The workload MUST NOT receive `CAP_NET_ADMIN` merely to participate in ZTS.

### 8.2 Identity binding

On a single host, ingress interface provenance MAY be used as a strong local binding between kernel-created endpoint and workload identity.

Source IP MUST NOT be the only identity proof used by policy.

### 8.3 nftables

The default forwarding policy MUST be deny.

Explicit allow rules SHOULD be generated from desired relations.

Established/related return traffic MAY be allowed through conntrack.

Anti-spoofing rules SHOULD constrain traffic from each workload endpoint to its assigned provider address set.

### 8.4 Routing

Routes and policy-routing tables are provider materialization details.

Default routing MUST NOT accidentally expose host/LAN/WAN connectivity.

### 8.5 Host transport and the private-space guard

A `host` transport attaches the substrate namespace to the host through a dedicated veth link and masquerades the workload pool out of the host's default route. The guard applies to everything leaving by that link: destinations in `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.168.0.0/16`, `224.0.0.0/4` and `240.0.0.0/4` are dropped unless a resource declares a CIDR that lies entirely inside one of those ranges, or the transport sets `allow_private: true`. `0.0.0.0/0` does not count as declaring private space.

### 8.6 WireGuard

WireGuard is a transport mechanism, not the ZTS authorization engine.

A WireGuard interface MAY be created in the host namespace and moved into the ZTS namespace so that its encrypted UDP socket retains access to the host underlay while plaintext exists only inside the substrate namespace.

ZTS MAY use WireGuard for:

- remote ZTS host links;
- isolated egress gateways;
- proxy gateways;
- encrypted overlays carried over another transport.

---

## 9. Proxies

A proxy is an optional policy boundary reached through ZTS routing.

A proxy MAY provide:

- HTTP/API policy;
- credential brokerage/injection;
- secret isolation;
- method/resource restrictions;
- audit logging;
- rate limits;
- protocol translation;
- sandbox substitution where the application protocol allows it.

A proxy MUST NOT be required for traffic that only needs L3/L4 authorization.

A proxy holding external credentials SHOULD be unreachable except through explicitly materialized ZTS paths.

---

## 10. TLS behavior

ZTS distinguishes routing from cryptographic peer identity.

If a workload connects to the real `api.github.com`, normal end-to-end TLS can remain intact.

If policy redirects an application to an alternate service, that alternate MUST satisfy whatever cryptographic validation the application performs. ZTS does not require installing a private CA or intercepting arbitrary TLS.

Therefore:

```text
real destination + strict TLS      -> supported
no route                            -> supported
alternate destination when client accepts it -> supported
transparent counterfeit TLS peer   -> out of scope
```

---

## 11. Multi-host and carrier layering

Two ZTS environments MAY be joined over any carrier capable of transporting the chosen ZTS link.

Example:

```text
workload A
   |
ZTS host A
   |
inner WireGuard / ZTS ciphertext
   |
Tailscale subnet/carrier
   |
ZTS host B
   |
workload B
```

The carrier sees only the outer transport-level relationship and whatever routing metadata is inherently exposed by that carrier.

ZTS policy remains responsible for workload-to-resource authorization.

A Tailscale deployment MAY therefore use coarse subnet/host connectivity while avoiding duplication of the full per-workload ZTS authorization model in Tailscale ACLs/grants.

Multiple carrier instances MAY be isolated in separate network namespaces, allowing one host to carry ZTS paths through different tailnets/accounts without making workloads members of those tailnets.

---

## 12. Secret and capability model

Target architecture distinguishes:

```text
identity       who originated the request/context
capability     what effect may be requested
route          where that request may travel
mediation      how extra policy is applied
credential     how a legacy/external system realizes authority
```

Workloads SHOULD receive capabilities rather than raw long-lived credentials where a proxy can safely mediate the external protocol.

This is target architecture; `zts.sh` v0 does not yet implement signed capability grants or credential brokerage.

---

## 13. Manifest validation

A reconciler MUST reject a manifest when:

- referenced profiles/resources/transports do not exist;
- address spaces are invalid;
- required transport key material is absent;
- conflicting materializations would cause ambiguous routing;
- a desired relation cannot be represented safely by the selected provider.

Unknown fields SHOULD be rejected or explicitly namespaced for forward compatibility rather than silently ignored.

---

## 14. Drift

The following are examples of drift:

- a managed container restarted and has a new netns;
- a required veth disappeared;
- an nftables rule was modified manually;
- a transport interface is absent;
- a profile changed;
- a managed workload disappeared but provider state remains;
- a new labeled workload appeared with no materialized endpoint.

The next reconcile MUST move actual state toward desired state without requiring container recreation.

---

## 15. Reference CLI

Reference commands:

```text
zts.sh init     [manifest]   write a manifest from a preset
zts.sh check    [manifest]   validate a manifest without root
zts.sh edit     [manifest]   edit in $EDITOR; only a valid result is saved
zts.sh show     [manifest]   print the manifest
zts.sh load     [manifest]   replace the manifest from stdin, after validation
zts.sh plan     [manifest]
zts.sh apply    [manifest]
zts.sh status   [manifest]
zts.sh up       [manifest]   apply, then reconcile on container events and manifest changes
zts.sh destroy  [manifest]
zts.sh selftest
```

Two implementations exist and pass the same acceptance suite: the Go core (one static binary; the default container image) and the bash essentials (one readable file; `Dockerfile.bash`). Run as `--privileged --pid=host --network host` with the Docker socket, either creates the substrate namespace in the host's mount namespace so that state outlives the controller. This is the documented path for Docker Desktop, where the host is Docker's own Linux VM. Both refuse to operate if the namespace they open turns out to be the host's own.

A future implementation MAY replace Bash with another ephemeral reconciler while preserving the same architecture and invariants.

A future implementation SHOULD NOT become an always-on privileged dataplane daemon merely for convenience.

---

## 16. Current v0.2 implementation status

Implemented in both the Go core and the bash essentials:

- Docker discovery by label through the Engine API (read-only);
- IPv4;
- deterministic workload endpoint allocation from a pool;
- Linux network namespace/veth materialization;
- deny-first nftables policy with per-endpoint anti-spoofing;
- same-host workload resources;
- CIDR resources;
- name-based resources via per-profile gateway resolvers and kernel sets (no proxy);
- `host` transport with the private-space guard;
- WireGuard transports;
- convergence detection (`plan` reports `No changes.` on converged state);
- `init` presets, `check`, `plan`, `apply`, `status`, `up`, `destroy`, `selftest`;
- container image for Linux and Docker Desktop;
- nothing in the packet path after apply;
- resolvers that outlive the controller (Go core only).

Not yet implemented:
- signed grants/certificates;
- dynamic service discovery;
- Tailscale and Cloudflare transport adapters;
- multiple Linux provider namespaces/carrier namespaces;
- L7 proxy implementation;
- secret brokerage;
- IPv6;
- durable state journal/transactional rollback;
- formal manifest schema file;
- OCI/containerd/Podman/Incus runtime adapters;
- Docker Desktop with Enhanced Container Isolation (blocks `--pid=host`).

---

## 17. Minimum acceptance tests

A conforming prototype SHOULD demonstrate at least:

1. An arbitrary `--network none` container gains a ZTS-managed interface without image modification.
2. Docker remains unmodified by ZTS network operations.
3. A workload with an empty profile cannot reach host, LAN, another workload, or internet.
4. An explicit same-host relation enables only the declared protocol/port.
5. A transport-bound relation exits only through the declared transport.
6. Removing ZTS state returns the workload to no connectivity.
7. Re-running reconciliation produces no changes when desired and actual state already match.
8. Restarting a labeled container is detected as drift and reattached on the next reconcile.
9. A workload cannot gain new reachability by spoofing another workload's source address.
10. No ZTS-specific process must remain inside a workload after reconciliation.

---

## 18. Design test

When evaluating a proposed feature, ask:

> Does this need to become a new ZTS service, or can it remain declarative intent compiled into a primitive the platform already provides?

Prefer the latter until proven insufficient.
