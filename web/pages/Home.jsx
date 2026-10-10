import { Layout } from '../components/Layout.jsx';
import { Section, CodePanel } from '../components/Section.jsx';
import { Why } from '../components/Why.jsx';

const IMAGE = 'ghcr.io/spektral-tech/zts';

// The quickstart, exactly what scripts/two-minutes.sh runs.
const QUICKSTART = [
  `docker run --rm -it -v zts:/etc/zts ${IMAGE} init`,
  `docker run -d --name zts --restart unless-stopped --privileged --pid=host --network host \\\n    -v /var/run/docker.sock:/var/run/docker.sock -v zts:/etc/zts ${IMAGE} up`,
  'docker run -d --name agent --network none --label zts.profile=dev alpine sleep infinity',
  'docker exec agent wget -qO- https://api.github.com/zen',
];

// The simulated session: prompt lines and their output, with a tone per line.
const CAST = [
  { cmd: 'docker run -d --name agent-dev --network none \\\n  --label zts.profile=dev alpine sleep infinity' },
  { out: '7b0d5f6d9e4a', tone: 'dim' },
  { gap: true },
  { cmd: 'docker logs zts | tail -4' },
  { out: '[zts] event: start agent-dev', tone: 'route' },
  { out: '[zts] reconcile workload agent-dev', tone: 'add' },
  { out: '[zts] reconcile nftables', tone: 'add' },
  { out: '[zts] converged (1 workload(s))', tone: 'add' },
  { gap: true },
  { cmd: 'docker exec agent-dev wget -qO- https://api.github.com/zen' },
  { out: 'Keep it logically awesome.', tone: 'dim' },
  { cmd: 'docker exec agent-dev wget -T3 -qO- https://example.com' },
  { out: "wget: bad address 'example.com'", tone: 'dim' },
  { gap: true },
  { cmd: "docker inspect -f '{{.HostConfig.NetworkMode}}' agent-dev" },
  { out: 'none', tone: 'dim' },
];

const MANIFEST_YAML = `<span class="key">transports:</span>
  <span class="key">host:</span> { <span class="key">type:</span> host }

<span class="key">resources:</span>
  <span class="key">accounting-db:</span> { <span class="key">workload:</span> accounting-db }
  <span class="key">github:</span> { <span class="key">names:</span> [github.com, "*.github.com"] }

<span class="key">profiles:</span>
  <span class="key">isolated:</span>
    <span class="key">allow:</span> []

  <span class="key">dev:</span>
    <span class="key">allow:</span>
      - { <span class="key">to:</span> accounting-db, <span class="key">protocol:</span> tcp, <span class="key">ports:</span> [5432] }
      - { <span class="key">to:</span> github, <span class="key">via:</span> host, <span class="key">protocol:</span> tcp, <span class="key">ports:</span> [443] }`;

const PIPELINE = [
  ['Discover', <>Read labeled <code>--network none</code> containers and their netns. No Docker network writes.</>],
  ['Compare', 'Resolve manifest intent and inspect current kernel state.'],
  ['Plan', 'Compute missing, changed and orphaned materialization.'],
  ['Apply', 'Converge netns, veth, routes, nftables and WireGuard.'],
  ['Leave the packet path', 'Native dataplane state does the work. The controller only wakes up when a container starts or stops.'],
];

const INVARIANTS = [
  'An arbitrary unmodified container must be unable to bypass the substrate.',
  'The native state of a managed workload is no connectivity.',
  'Identity gives policy trustworthy provenance. It does not grant trust.',
  'Policy compiles into native dataplane state; ZTS is not a packet-by-packet policy daemon.',
  'Proxies are optional next hops for L7 policy, not mandatory chokepoints.',
  'Carriers transport the fabric. They do not own workload authorization.',
  'Paths that cross a trust boundary are authenticated by the transport before they become reachable.',
  'External credentials may remain opaque to the workload; infrastructure can exercise them only for authorized effects.',
  'Ingress adapters are workloads too: authentication to an external tunnel provider never implies ambient internal reachability.',
  'ZTS must be auditable as native state. Security must not depend on trusting a proprietary resident ZTS dataplane daemon.',
];

const LAYERS = [
  ['APPLICATION', 'ordinary software', 'Does not know ZTS exists.'],
  ['L7 / OPTIONAL', 'policy proxy / credential broker', 'Opaque credentials, method policy, audit, translation.'],
  ['SUBSTRATE', 'ZTS', 'Workload reachability and route materialization.', true],
  ['TRANSPORT AUTHN', 'WireGuard / authenticated carrier', 'Proves the transport peer before a remote path can exist.'],
  ['CARRIER', 'Tailscale / LAN / relay', 'Moves opaque transport traffic between places without owning workload policy.'],
  ['UNDERLAY', 'host / LAN / internet', 'Infrastructure the workload never receives directly.'],
];

// Manifesto articles: title, paragraphs (trusted markup), optional quote.
const MANIFESTO = [
  ['Trust is never ambient.', ['Being on the same host, LAN, tailnet, bridge, cluster, or cloud account must not grant authority. A workload begins with no assumed path to anything.', 'Every connection exists because the workload identity, current context, destination and policy make that specific path legitimate.']],
  ['Identity is not trust.', ['Knowing that container A is container A solves provenance. It does not make every action by A trustworthy. Identity is evidence supplied to policy. Nothing more.', 'A workload may be known perfectly and still have no path to another workload, no route to the internet, and no right to reach a proxy.']],
  ['No network by default.', ['The substrate does not join an existing LAN and then filter it. It materializes only the paths that should exist. If no grant produces a path, there is no path.'], 'Prefer absence over rejection. Prefer <code>unreachable</code> over <code>403</code>.'],
  ['The application does not participate.', ['ZTS must work with an arbitrary unmodified container image. No SDK. No sidecar. No injected agent. No custom entrypoint. No application-aware firewall library. No secret mounted into the workload.', 'The application sees an ordinary network interface and ordinary destinations. Everything below that interface is infrastructure.']],
  ['Policy declares relationships, not commands.', ['The manifest says which identities may reach which resources, through which trust boundary, and under what context. It does not prescribe interface names, routing table numbers or firewall commands.', 'How that policy becomes Linux state is implementation detail, not the security model.']],
  ['Docker is inventory, not authority.', ['A workload can be created normally with <code>--network none</code> and labels describing its binding. ZTS reads metadata, finds the network namespace, observes drift, and materializes Linux state directly.', 'If every ZTS object disappears, the workload falls back to no network. Fail closed is the baseline.']],
  ['Use the kernel before inventing a platform.', ['Network namespaces, veth pairs, routes, policy routing, nftables, WireGuard, and ordinary proxies are enough to express the core model. ZTS does not need a privileged always-on daemon in every packet path.'], 'Boring is a security feature.'],
  ['Reachability first. Mediation only when necessary.', ['The answer to a request may be nowhere, another local workload, a remote ZTS fabric, direct internet egress, or a proxy that applies additional policy. A proxy is an optional next hop, not the primary firewall.']],
  ['Do not counterfeit cryptographic identity.', ['ZTS is not a TLS interception system. When software requires the real <code>api.github.com</code>, give it the real peer over end-to-end TLS or deny the path. Substitution is only valid when the application contract permits substitution.']],
  ['Locality is an implementation detail.', ['A permitted peer may be in the same host, another rack, a home server, a cloud region, behind Tailscale, or behind another encrypted carrier. The workload asks for a resource. The substrate materializes a viable permitted path.']],
  ['Carriers are not authorities.', ['WireGuard, Tailscale, direct LAN links and relays can carry ZTS traffic. They do not define workload policy. A carrier may know that host A can reach host B without learning which workload may reach which database.']],
  ['Authenticate the transport.', ['Carrier reachability is not enough across a trust boundary. The remote path must be cryptographically authenticated before ZTS treats it as a valid substrate link.', 'The carrier answers <em>can these hosts exchange packets?</em> Transport authn answers <em>did this path terminate at the expected substrate peer?</em> ZTS policy answers <em>may this workload use it?</em>']],
  ['Opaque credentials make authentication infrastructure.', ['A workload should receive the ability to cause permitted effects, not necessarily the credential used to cause them. A policy proxy can authenticate outward from certified workload context while bearer tokens, API keys, passwords, client certificates, or signing keys remain outside the workload.']],
  ['Do not trust us either.', ['ZTS is not an authority you must install. You do not need our shell, binary, daemon or service. Understand the invariants, implement them yourself, and inspect the resulting native state.', 'The reference implementation is evidence that the model can be materialized. It is not part of the trust requirement.'], null, 'manifesto-emphasis'],
  ['Trust must be inspectable.', ['ZTS should reduce to ordinary, inspectable security boundaries: network namespaces, routes, nftables, authenticated transports and explicit proxy edges. The mechanism can vary; the trust relationship must remain visible.'], 'If the only reason a path is safe is “trust our daemon,” it is not the model.'],
  ['One sentence.', ['<strong>ZTS gives any unmodified workload only the network paths its identity and context are explicitly authorized to use, with no ambient trust and no required daemon in the packet path.</strong>']],
];

const Raw = ({ as: Tag = 'p', html, ...rest }) => <Tag {...rest} dangerouslySetInnerHTML={{ __html: html }} />;

export function Home({ version, assets }) {
  return (
    <Layout title="ZTS — the network is derived state"
            description="ZTS gives each container only the network paths its profile declares. No proxy, no SDK, no ambient trust. One docker run."
            current="home" version={version} assets={assets}>
      <main id="main">
        <section class="hero" id="top">
          <p class="eyebrow">ZTS / v{version} · PRE-RELEASE</p>
          <h1>Run anything.<br />Anywhere.<br /><em>Trust no one.</em></h1>
          <p class="lede">ZTS gives any unmodified container only the network paths its profile declares. By name, by port, by transport. No proxy, no SDK, no CA, no ambient trust. Everything else is unreachable by construction.</p>
          <div class="hero-actions">
            <a class="primary" href="#start">Start in two minutes</a>
            <a href="#why">Is this for me?</a>
          </div>
          <div class="axiom" aria-label="Zero trust axioms">
            <span>identity proves origin</span><b>≠</b><strong>trust</strong><b>·</b><span>no grant</span><b>→</b><strong>no path</strong>
          </div>
        </section>

        <Why />

        <Section id="start" cls="start" eyebrow="TWO MINUTES / ONLY DOCKER"
                 title="Four commands. One question. Nothing installed on the host."
                 lede="Linux or Mac. The controller runs as a container, reaches the kernel through Docker's own VM or your host, and leaves only inspectable native state behind.">
          <CodePanel title="terminal" note="copy, paste, done" label="Quickstart" id="quickstart"
                     html={'<code>' + QUICKSTART.map((c) => `<span class="cast-prompt">$</span> ${c}`).join('\n') + '</code>'}>
            <p>The first command asks what your containers will do and writes an editable <code>zts.yaml</code>. The second starts the controller. The third is any image you like, with <code>--network none</code> and one label; the network it is allowed to perceive appears as it starts. The fourth proves it: GitHub answers, and <code>example.com</code> does not even resolve. Swap <code>dev</code> for <code>isolated</code> and nothing answers. Everything else is in the <a href="reference.html">docs</a>.</p>
          </CodePanel>
        </Section>

        <Section id="cli" cls="cli" eyebrow="WHAT HAPPENS / INSPECTABLE" title="Reference implementation, not trust anchor."
                 lede={<>The reference shell shows one way to apply the model with ordinary Linux primitives: discover labeled <code>--network none</code> workloads, attach only their authorized paths, resolve only declared names, then get out of the packet path.</>}>
          <div class="cli-grid">
            <div class="cli-copy">
              <p>Use it, replace it, instrument containerd directly, or reproduce the same invariants by hand. The CLI demonstrates one implementation; ZTS does not depend on it.</p>
              <p class="aside">Docker remains inventory-only. After convergence it can still report <code>NetworkMode=none</code>.</p>
            </div>
            <div class="cast" id="cli-cast" aria-label="Simulated ZTS command line session">
              <div class="cast-bar">
                <span class="cast-dots" aria-hidden="true"><i></i><i></i><i></i></span>
                <span class="cast-label">asciinema / simulated session</span>
                <button class="cast-replay" type="button" id="cast-replay">replay ↻</button>
              </div>
              <pre class="cast-screen"><code>{CAST.map((l, i) => (
                <>
                  {l.gap ? <span class="cast-line cast-gap"> </span>
                    : l.cmd ? <span class="cast-line"><span class="cast-prompt">$</span> <span class="cast-command">{l.cmd}</span></span>
                    : <span class={`cast-line cast-${l.tone}`}>{l.out}</span>}
                  {i < CAST.length - 1 ? '\n' : ''}
                </>
              ))}</code></pre>
              <div class="cast-footer"><span>v{version} pre-release</span><span>manifest → kernel state</span></div>
            </div>
          </div>
        </Section>

        <Section id="model" cls="sim" titleId="sim-title" eyebrow="ONE REQUEST / THREE REALITIES"
                 title="The workload asks. The substrate decides whether a path exists."
                 lede="The application is unchanged. Select a profile to see the same logical request materialize differently.">
          <div class="profile-switch" role="group" aria-label="Workload profile">
            {['isolated', 'development', 'release'].map((p) => (
              <button type="button" data-profile={p} aria-pressed={p === 'development' ? 'true' : 'false'}>{p}</button>
            ))}
          </div>
          <div class="topology" data-topology="development">
            <article class="node workload">
              <small>WORKLOAD</small><strong>agent-17</strong><span>GET api.github.com</span><code>eth0</code>
            </article>
            <div class="wire wire-a" aria-hidden="true"><i></i></div>
            <article class="substrate-node">
              <small>NATIVE LINUX</small><strong>ZTS</strong>
              <dl>
                <div><dt>identity</dt><dd>agent-17</dd></div>
                <div><dt>profile</dt><dd id="profile-value">development</dd></div>
                <div><dt>decision</dt><dd id="decision-value">sandbox egress</dd></div>
              </dl>
            </article>
            <div class="branch" aria-hidden="true">
              <span class="branch-line sandbox-line"></span><span class="branch-line real-line"></span>
            </div>
            <div class="destinations">
              <article class="node destination sandbox" data-dest="sandbox"><small>OPTIONAL L7</small><strong>dev proxy</strong><span>isolated / brokered</span></article>
              <article class="node destination real" data-dest="real"><small>DIRECT TLS</small><strong>GitHub</strong><span>real WAN destination</span></article>
              <article class="node destination none" data-dest="none"><small>NO PATH</small><strong>∅</strong><span>unreachable by construction</span></article>
            </div>
          </div>
          <p class="sim-caption" id="sim-caption">Development can reach GitHub only through the sandbox egress. The workload never chooses that realm.</p>
        </Section>

        <Section id="ingress" cls="ingress" eyebrow="ZERO PHYSICAL INGRESS / SAME RULES IN REVERSE"
                 title="An authenticated tunnel is still just an untrusted workload."
                 lede="A tunnel daemon may authenticate strongly to an external provider and keep every physical inbound port closed. ZTS still gives that daemon no ambient LAN, host or container access. It receives only the internal path explicitly materialized for its certified context.">
          <div class="ingress-stage" aria-label="Constrained ingress path through an authenticated tunnel">
            {[
              ['', 'PUBLIC REQUEST', 'Internet', 'No service port is opened on the host.', 'physical ingress = 0'],
              ['cloudflare', 'AUTHENTICATED TUNNEL', 'cloudflared', 'Strong tunnel authentication does not grant lateral trust.', 'identity = ingress/cloudflare'],
              ['substrate-ingress', 'SUBSTRATE', 'ZTS', 'Evaluates the adapter context and materializes only the permitted next hop.', 'allow → app:web:443'],
              ['', 'INTERNAL WORKLOAD', 'web', 'Not attached to LAN. Not published on the host.', 'reachable only through ZTS'],
            ].map(([cls, small, strong, span, code], i, all) => (
              <>
                <article class={cls ? `ingress-node ${cls}` : 'ingress-node'}>
                  <small>{small}</small><strong>{strong}</strong><span>{span}</span><code>{code}</code>
                </article>
                {i < all.length - 1 && <div class="ingress-arrow" aria-hidden="true"></div>}
              </>
            ))}
          </div>
          <div class="ingress-denied" aria-label="Paths not granted to the tunnel adapter">
            <div><b>Host</b><span>no route</span></div>
            <div><b>LAN</b><span>no route</span></div>
            <div><b>Other workloads</b><span>no route unless explicitly granted</span></div>
          </div>
          <div class="trust-note">
            <strong>Do not trust the tunnel. Do not trust us.</strong>
            <p>ZTS does not ask you to replace Cloudflare's trust with ours. The reconciler compiles declared intent into inspectable native Linux state and exits. The security boundary is the kernel state you can audit: namespaces, routes, nftables and authenticated transports — not a proprietary packet daemon that must remain trusted forever.</p>
          </div>
        </Section>

        <section class="self-trust" id="trust-us" aria-labelledby="trust-us-title">
          <div class="self-trust-mark" aria-hidden="true">∅</div>
          <div>
            <p class="eyebrow">IMPLEMENTATION INDEPENDENCE</p>
            <h2 id="trust-us-title">You do not need to trust us either.</h2>
            <p>ZTS is a model, a manifest semantics and a set of observable invariants. You do not need our shell, our binary, our daemon, our control plane, or even our implementation choices.</p>
            <p>Read how it works. Inspect the native state. Reproduce it yourself with Linux primitives, instrument your own runtime, or build another provider. If the resulting workload starts isolated, receives only declared paths, preserves transport authentication boundaries and fails closed, the substrate property exists without us in the trust chain.</p>
            <div class="trust-equation"><span>understand</span><b>→</b><span>instrument</span><b>→</b><span>inspect</span><b>→</b><strong>trust the state</strong></div>
          </div>
        </section>

        <section class="split" id="declaration">
          <div class="section-head sticky-copy">
            <p class="eyebrow">DECLARATIVE, NOT IMPERATIVE</p>
            <h2>Describe the world. Do not script the network.</h2>
            <p>The manifest says which relationships should exist. The Linux provider chooses veth names, routes, tables, nftables state and WireGuard materialization.</p>
            <p class="aside">Declare relationships. Let infrastructure enforce them.</p>
          </div>
          <CodePanel title="zts.yaml" note="policy intent" label="Example ZTS manifest" html={'<code>' + MANIFEST_YAML + '</code>'}>
            <p>There is no <code>ip link add</code>, interface name, routing table number or firewall command in the policy declaration. A name is resolved by the workload's own gateway and the answer becomes the authorization: no proxy, no CA, TLS end to end.</p>
          </CodePanel>
        </section>

        <Section cls="flow" titleId="flow-title" eyebrow="RECONCILIATION" title="Docker is inventory. Linux is the provider.">
          <ol class="pipeline">
            {PIPELINE.map(([name, text], i) => (
              <li><span>{String(i + 1).padStart(2, '0')}</span><strong>{name}</strong><p>{text}</p></li>
            ))}
          </ol>
        </Section>

        <Section id="invariants" cls="principles" eyebrow="INVARIANTS" title="Small surface. Hard boundaries.">
          <div class="rules">
            {INVARIANTS.map((t, i) => <article><span>{String(i + 1).padStart(2, '0')}</span><p>{t}</p></article>)}
          </div>
        </Section>

        <Section cls="layers" titleId="layers-title" eyebrow="COMPOSABLE TRUST" title="Use each layer for the smallest job it is good at.">
          <div class="layer-stack">
            {LAYERS.map(([tag, name, text, active]) => (
              <div class={active ? 'active' : undefined}><span>{tag}</span><strong>{name}</strong><p>{text}</p></div>
            ))}
          </div>
        </Section>

        <Section id="capabilities" cls="capabilities" eyebrow="AUTHORITY WITHOUT AMBIENT TRUST" title="Authenticate the path. Keep the credential opaque."
                 lede="Two capabilities are part of ZTS itself, not roadmap garnish: remote transport can require cryptographic peer authentication, and external authentication can be exercised by infrastructure without handing the underlying credential to the workload.">
          <div class="cap-rows">
            <article class="cap-row">
              <span class="cap-index">01 / TRANSPORT AUTHN</span>
              <strong>Remote reachability begins with an authenticated transport.</strong>
              <p>WireGuard public keys bind a remote substrate peer to the encrypted path. Tailscale, LAN, relays or other carriers may carry that path, but the carrier does not become the workload authorization authority.</p>
              <code>workload → policy → authenticated transport → remote substrate</code>
            </article>
            <article class="cap-row">
              <span class="cap-index">02 / OPAQUE CREDENTIALS</span>
              <strong>Authentication can be infrastructure, not application state.</strong>
              <p>A policy proxy can authenticate outward from certified workload context while the bearer token, API key, password or signing key remains outside the workload. The workload receives the permitted effect, not the reusable secret.</p>
              <code>identity + request + policy → brokered authn → external effect</code>
            </article>
          </div>
        </Section>

        <section class="manifesto-section" id="manifesto" aria-labelledby="manifesto-title">
          <div class="manifesto-layout">
            <aside class="manifesto-aside">
              <p class="eyebrow">THE MANIFESTO</p>
              <h2 id="manifesto-title">No ambient network.<br />No ambient trust.</h2>
              <p>This is not documentation you must accept on authority. It is the model in plain language, so you can implement and falsify it yourself.</p>
              <a class="quiet-manifest-link" href="MANIFESTO.md" download>plain Markdown ↓</a>
            </aside>
            <div class="manifesto-doc">
              {MANIFESTO.map(([title, paras, quote, cls]) => (
                <article class={cls}>
                  <h3>{title}</h3>
                  {paras.map((p) => <Raw html={p} />)}
                  {quote && <Raw as="blockquote" html={quote} />}
                </article>
              ))}
            </div>
          </div>
        </section>

        <section class="status" id="status">
          <div class="status-copy">
            <p class="eyebrow">REFERENCE IMPLEMENTATION / BASH ESSENTIALS</p>
            <h2>You can read all of <code>zts.sh</code>. You do not need to trust it.</h2>
            <p>v{version} ships two implementations that pass the same acceptance suite: a Go core, one static binary, which is the image above; and the bash essentials, one readable file that does the most with the least. They agree on every derived name and address. Neither is an authority: the mechanism is inspectable native state. Run either directly on a Linux host:</p>
            <div class="commands" aria-label="ZTS CLI example">
              <pre><code>{'$ ./zts.sh check zts.yaml\n$ sudo ./zts.sh plan zts.yaml\n$ sudo ./zts.sh apply zts.yaml\n$ sudo ./zts.sh status zts.yaml'}</code></pre>
            </div>
          </div>
          <div class="status-grid">
            <div><strong>implemented in v{version}</strong><p>{['Go core and bash essentials, in parity', 'read-only Docker discovery', 'IPv4 · netns + veth', 'deny-first nftables', 'same-host workload resources', 'names via gateway DNS, no proxy', 'host transport with private-space guard', 'WireGuard transports', 'controller on container events', 'presets on first run'].map((t, i, a) => <>{t}{i < a.length - 1 && <br />}</>)}</p></div>
            <div><strong>not yet</strong><p>{['Tailscale and Cloudflare transports', 'policy proxy with opaque credentials', 'IPv6', 'Podman, containerd, Kubernetes', 'multi-host fabric'].map((t, i, a) => <>{t}{i < a.length - 1 && <br />}</>)}</p></div>
          </div>
        </section>
      </main>
    </Layout>
  );
}
