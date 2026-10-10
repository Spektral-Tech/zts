// The page registry: path -> rendered HTML. The build writes these to site/.
import { render } from 'preact-render-to-string';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Home } from './pages/Home.jsx';
import { DocPage } from './pages/DocPage.jsx';

export function pages(root) {
  const version = readFileSync(join(root, 'VERSION'), 'utf8').trim();
  const doc = (slug, title, description, source) =>
    render(<DocPage slug={slug} title={title} description={description} source={source}
                    text={readFileSync(join(root, source), 'utf8')} version={version} />);
  return {
    'index.html': render(<Home version={version} />),
    'reference.html': doc('docs', 'ZTS — Docs', 'ZTS reference: install, command line, zts.yaml, scenarios, what to expect, running without the image.', 'REFERENCE.md'),
    'spec.html': doc('spec', 'ZTS — Technical Specification', 'ZTS technical specification: trust model, invariants, manifest, reconciliation, Linux provider, implementation status.', 'SPEC.md'),
  };
}
