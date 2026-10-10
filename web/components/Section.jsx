// Section with the eyebrow / title / lede head used across the landing page.
export function Section({ id, cls, eyebrow, title, titleId, lede, headCls, children, ...rest }) {
  const hid = titleId || (id ? `${id}-title` : undefined);
  return (
    <section class={cls} id={id} aria-labelledby={title ? hid : undefined} {...rest}>
      {title && (
        <div class={headCls ? `section-head ${headCls}` : 'section-head'}>
          {eyebrow && <p class="eyebrow">{eyebrow}</p>}
          <h2 id={hid}>{title}</h2>
          {lede && <p>{lede}</p>}
        </div>
      )}
      {children}
    </section>
  );
}

// A framed code block with a title bar. `html` is trusted, pre-escaped markup.
export function CodePanel({ title, note, label, id, html, children }) {
  return (
    <div class="code-panel" aria-label={label}>
      <div class="code-title"><span>{title}</span><span>{note}</span></div>
      <pre id={id} dangerouslySetInnerHTML={{ __html: html }} />
      {children}
    </div>
  );
}
