import { Topbar } from './Topbar.jsx';
import { Footer } from './Footer.jsx';

// Every page: one head, one top bar, one footer. Asset URLs carry a content
// hash so a changed stylesheet or script never meets a stale cache.
export function Layout({ title, description, current, version, assets, bodyClass, children }) {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="description" content={description} />
        <meta name="theme-color" content="#0b0b0b" />
        <title>{title}</title>
        <link rel="stylesheet" href={`styles.css?v=${assets['styles.css']}`} />
        <script defer src={`app.js?v=${assets['app.js']}`}></script>
      </head>
      <body class={bodyClass}>
        <a class="skip" href="#main">Skip to content</a>
        <Topbar current={current} />
        {children}
        <Footer />
      </body>
    </html>
  );
}
