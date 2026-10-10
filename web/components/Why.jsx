import { Section } from './Section.jsx';

// Orientation for someone who will not read the manifesto first: what it
// does, who it is for, when it is the right tool, and when it is not.
export const FEATURES = [
  ['Nothing by default', 'A managed container starts with no LAN, no host, no internet, no other containers. Every path exists because the manifest declared it.'],
  ['Names without a proxy', 'Allow <code>github.com</code>, not an IP list. The container\'s own resolver answers only declared names and the answer becomes the authorization. No CA, no environment variable, TLS end to end.'],
  ['Any image, unchanged', 'No SDK, no sidecar, no entrypoint. <code>--network none</code> and one label. The application sees an ordinary <code>eth0</code>.'],
  ['Ports and protocols', 'Relations are <code>to</code>, <code>via</code>, <code>protocol</code>, <code>ports</code>. A database profile that only accepts 5432 from the app, and nothing from anyone else.'],
  ['Out through the host or a tunnel', 'Egress via the host\'s own route, with private and link-local space guarded, or via WireGuard to a remote gateway.'],
  ['Nothing in the packet path', 'Policy is compiled into namespaces, routes and nftables. The controller only wakes up when a container starts or stops. Inspect the state with <code>nft</code> and <code>ip</code>.'],
  ['One docker run', 'Linux or Mac with Docker Desktop. The controller is a container; the host installs nothing.'],
  ['Readable', 'A Go core and a one-file bash reference pass the same acceptance suite. Read the file, or the kernel state, instead of trusting a daemon.'],
];

export const FOR_WHOM = [
  ['You run coding agents', 'An agent with a shell and your tokens should reach GitHub and the model API, and nothing else on your machine or network.'],
  ['You run code you did not write', 'Third-party tools, build steps, evaluation jobs. Give them the registry they need and no route to your LAN.'],
  ['You give workloads credentials', 'When a token leaks, the damage is bounded by where the workload could go. Let the network decide, not the application.'],
  ['You have docker run, not a cluster', 'Network policy for a laptop, a home server or a single VM, without Kubernetes, a service mesh or a proxy per app.'],
];

export const WHEN = [
  'An agent, a scraper or a notebook needs the internet, but your home or office network must stay invisible to it.',
  'A CI or build job must reach the package registry and nothing else.',
  'A service must only talk to its database, and the database must only hear from that service.',
  'You want to prove, not promise, that a container cannot reach the LAN: the proof is kernel state you can list.',
];

export const NOT_WHEN = [
  ['Kubernetes', 'use its network policies or a CNI that enforces them. ZTS is for hosts that run Docker.'],
  ['HTTP-level rules', 'methods, paths, request bodies are a proxy\'s job. ZTS can route a workload to one, it does not replace it.'],
  ['IPv6-only, Windows containers, Podman', 'not yet.'],
];

const Raw = ({ as: Tag = 'p', html, ...rest }) => <Tag {...rest} dangerouslySetInnerHTML={{ __html: html }} />;

export function Why() {
  return (
    <Section id="why" cls="why" eyebrow="IN SHORT / BEFORE YOU READ EVERYTHING"
             title="What it does, who it is for, when you need it."
             lede="Everything below is implemented and tested in the current release. The manifesto explains why; the docs explain how.">
      <div class="why-grid">
        <div class="why-col">
          <h3>Features</h3>
          <ul class="why-list">
            {FEATURES.map(([t, d]) => <li><strong>{t}</strong><Raw html={d} /></li>)}
          </ul>
        </div>
        <div class="why-col">
          <h3>Who it is for</h3>
          <ul class="why-list">
            {FOR_WHOM.map(([t, d]) => <li><strong>{t}</strong><p>{d}</p></li>)}
          </ul>
          <h3>When you need it</h3>
          <ul class="why-list why-plain">
            {WHEN.map((t) => <li><p>{t}</p></li>)}
          </ul>
          <h3>When you do not</h3>
          <ul class="why-list">
            {NOT_WHEN.map(([t, d]) => <li><strong>{t}</strong><p>{d}</p></li>)}
          </ul>
        </div>
      </div>
      <div class="why-compare" aria-label="How ZTS differs">
        <div><span>agent sandboxes</span><p>filter through an HTTP proxy: the app must honor <code>HTTP_PROXY</code>, and only TLS on 443 is covered. SSH, databases, UDP and QUIC fall outside.</p></div>
        <div><span>meshes and VPN ACLs</span><p>authorize hosts, tags or subnets. Every container on the host inherits the same reach.</p></div>
        <div class="active"><span>ZTS</span><p>authorizes per container, at the network layer, by name, port and transport, for any protocol, with no proxy and nothing in the packet path. Meshes and proxies still have their place: ZTS routes to them.</p></div>
      </div>
    </Section>
  );
}
