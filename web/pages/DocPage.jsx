import { Layout } from '../components/Layout.jsx';
import { markdown } from '../markdown.js';

// A long document rendered from its Markdown source, with the source itself
// available for download next to it.
export function DocPage({ slug, title, description, source, text, version }) {
  return (
    <Layout title={title} description={description} current={slug} version={version} bodyClass={`page-${slug}`}>
      <main id="main" class="doc">
        <p class="doc-source"><a href={source} download>{source} ↓</a></p>
        <article dangerouslySetInnerHTML={{ __html: markdown(text) }} />
      </main>
    </Layout>
  );
}
