# ZTS

## The network is derived state.

A workload should not inherit a network merely because it exists on a host.

It should begin with nothing.

No LAN. No host. No internet. No implicit east-west reachability. No ambient authority.

Connectivity should exist only as the materialized consequence of declared intent, proven identity, current policy, and available transport.

That is ZTS.

---

## Identity is not trust

Knowing that container A is container A solves provenance. It does not make every action by A trustworthy.

Identity is evidence supplied to policy. Nothing more.

A workload may be known perfectly and still have no path to another workload, no route to the internet, and no right to reach a proxy.

The substrate turns identity into *questions that can be answered safely*, not blanket permission.

---

## No network by default

A managed workload is created with no network.

The substrate does not join an existing LAN and then filter it. It materializes only the paths that should exist.

If no grant produces a path, there is no path.

Prefer absence over rejection.

Prefer `unreachable` over `403`.

Prefer a topology that cannot express the forbidden connection over an application that promises not to use it.

---

## The application does not participate

ZTS must work with an arbitrary unmodified container image.

No SDK. No sidecar. No injected agent. No custom entrypoint. No application-aware firewall library. No secret mounted into the workload.

The application sees an ordinary network interface and ordinary destinations.

Everything below that interface is infrastructure.

This keeps the security property independent of the quality, age, language, framework, or integrity of the software inside the container.

---

## Declaration, not choreography

ZTS is not a script describing networking commands.

The manifest describes the network reality that should be true.

The reconciler observes runtime inventory and kernel state, computes drift, and converges Linux primitives toward that desired state.

The manifest says:

> development workloads may reach the accounting database and may reach the internet through the sandbox egress.

It does not say:

> create veth X, add route Y, append nftables rule Z.

Those are provider details.

The manifest is closer to Terraform than to a Dockerfile.

---

## Docker is inventory, not authority

Docker does not need to be modified by ZTS.

A workload can be created normally with `--network none` and labels describing its binding to a declared identity/profile.

ZTS reads container metadata, finds the network namespace, observes drift, and materializes the required Linux state directly.

Docker can continue to believe the container has `NetworkMode=none`.

That is intentional.

If every ZTS object disappears, the container falls back to its native state: no network.

Fail closed is not an emergency mode. It is the baseline.

---

## Use the kernel before inventing a platform

The substrate is composed from existing Linux primitives:

- network namespaces;
- veth pairs;
- routes and policy routing;
- nftables;
- WireGuard;
- ordinary proxies when application-layer mediation is actually required.

ZTS does not need a privileged always-on daemon sitting in every packet path.

Policy can be compiled into kernel state. The reconciler can leave.

The dataplane remains boring.

Boring is a security feature.

---

## Reachability first, mediation only when necessary

The substrate answers a small question:

> Where, if anywhere, may this workload send this traffic?

The answer may be:

- nowhere;
- another local workload;
- a remote ZTS fabric;
- direct internet egress;
- a proxy that applies additional policy.

A proxy is not the primary firewall. It is an optional next hop for cases that require L7 understanding, secret brokerage, auditing, protocol transformation, rate limiting, or contextual authority.

If L7 mediation is unnecessary, packets should not pay for it.

---

## Do not counterfeit cryptographic identity

ZTS is not a TLS interception system.

When an application requires the real `api.github.com`, ZTS can give it the real GitHub over end-to-end TLS or deny the path.

When an application can use a substitutable resource, policy may resolve that logical need to a sandbox, mirror, proxy, or other implementation.

The substrate controls reachability. It does not need to lie about who a cryptographic peer is.

---

## Locality is an implementation detail

A workload should not care whether a permitted peer is:

- in the same container host;
- in another rack;
- on a home server;
- in a cloud region;
- behind Tailscale;
- behind another encrypted carrier on the other side of the world.

The workload asks for a resource.

The substrate materializes a viable permitted path.

Locality belongs to the provider, not the application.

---

## Carriers are not authorities

WireGuard, Tailscale, direct LAN links, relays, and future transports can carry ZTS traffic.

They do not define workload policy.

A carrier may know that host A can transport packets to host B. It does not need to know which agent may reach which database or why one workload receives sandbox egress while another receives production egress.

Transport trust and workload authorization are different layers.

Keep them different.

---

## Secrets belong at the edge of authority

A workload should receive the ability to cause permitted effects, not necessarily the credential used to cause them.

When a remote system still requires a bearer token, API key, password, or signing key, a policy proxy may hold that credential and exercise it only for an authorized request.

Compromising a workload should expose the workload's current capabilities, not automatically every underlying secret that implements them.

---

## The substrate is a compiler

The useful mental model is not "zero-trust networking service."

It is:

```text
manifest + runtime identity + current topology
                    |
                    v
                  plan
                    |
                    v
      native Linux network state
```

The workload sees the output of that compilation as its network reality.

ZTS should remain small enough that this statement stays true.

---

## Core invariants

1. **An arbitrary unmodified container must be unable to bypass the substrate.**
2. **The native state of a managed workload is no connectivity.**
3. **Identity never implies blanket trust.**
4. **The manifest declares desired relationships, not networking commands.**
5. **Docker/runtime integration is read-only wherever possible.**
6. **Policy is compiled into native dataplane state rather than evaluated by a custom daemon for every packet.**
7. **Proxies are optional policy boundaries, not mandatory network chokepoints.**
8. **TLS identity is preserved; ZTS does not require MITM.**
9. **Carriers transport ZTS; they do not define ZTS workload authorization.**
10. **Removing ZTS state returns workloads to no network, not open network.**

---

## One sentence

**ZTS materializes the network each workload is allowed to perceive from declarative policy, using native infrastructure primitives and no application cooperation.**
