// The same top bar on every page. `current` marks where the reader is.
export const NAV = [
  { href: 'index.html#start', label: 'Start', key: 'start' },
  { href: 'index.html#model', label: 'Model', key: 'model' },
  { href: 'index.html#manifesto', label: 'Manifesto', key: 'manifesto' },
  { href: 'reference.html', label: 'Docs', key: 'docs' },
  { href: 'spec.html', label: 'Spec', key: 'spec' },
];

export function Topbar({ current }) {
  return (
    <header class="topbar">
      <a class="brand" href="index.html" aria-label="ZTS home">
        <img class="brand-mark" src="brand-mark.png" alt="" width="288" height="165" />
        <span>ZTS</span>
      </a>
      <nav aria-label="Primary">
        {NAV.map((n) => (
          <a href={current === 'home' && n.href.startsWith('index.html#') ? n.href.slice('index.html'.length) : n.href}
             aria-current={current === n.key ? 'page' : undefined}>{n.label}</a>
        ))}
      </nav>
      <a class="quiet-link" href="https://github.com/Spektral-Tech/zts" rel="noopener">Source →</a>
    </header>
  );
}
