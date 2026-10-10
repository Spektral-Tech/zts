// The subset of Markdown the published documents use: ATX headings,
// paragraphs, bullet and numbered lists, fenced code, blockquotes, rules,
// inline code/strong/em/strike. Deliberately small; the sources are ours.
import { highlight } from './highlight.js';

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

export function inline(text) {
  let t = esc(text);
  t = t.replace(/`([^`]+)`/g, '<code>$1</code>');
  t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  t = t.replace(/(?<![\w*])\*([^*\n]+)\*(?![\w*])/g, '<em>$1</em>');
  t = t.replace(/~~([^~]+)~~/g, '<s>$1</s>');
  return t;
}

export function slugify(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'section';
}

export function markdown(src) {
  const out = [];
  const lines = src.split('\n');
  let para = [];
  const flush = () => { if (para.length) { out.push('<p>' + inline(para.join(' ')) + '</p>'); para = []; } };
  const item = /^(\s*)([-*]|\d+\.)\s+(.*)$/;
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('```')) {
      flush();
      const lang = line.slice(3).trim();
      const buf = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('```')) buf.push(lines[i++]);
      i++;
      out.push(`<pre><code${lang ? ` class="lang-${lang}"` : ''}>${highlight(lang, buf.join('\n'))}</code></pre>`);
      continue;
    }
    let m = /^(#{1,6})\s+(.*)$/.exec(line);
    if (m) {
      flush();
      const text = m[2].trim();
      out.push(`<h${m[1].length} id="${slugify(text.replace(/[`*]/g, ''))}">${inline(text)}</h${m[1].length}>`);
      i++;
      continue;
    }
    if (/^\s*---+\s*$/.test(line)) { flush(); out.push('<hr>'); i++; continue; }
    if (line.startsWith('>')) {
      flush();
      const buf = [];
      while (i < lines.length && lines[i].startsWith('>')) buf.push(lines[i++].slice(1).trim());
      out.push('<blockquote><p>' + inline(buf.join(' ')) + '</p></blockquote>');
      continue;
    }
    m = item.exec(line);
    if (m) {
      flush();
      const ordered = /\d/.test(m[2][0]);
      const items = [];
      while (i < lines.length) {
        const m2 = item.exec(lines[i]);
        if (!m2 || /\d/.test(m2[2][0]) !== ordered) break;
        items.push(m2[3].trim());
        i++;
        while (i < lines.length && lines[i].startsWith('  ') && !item.test(lines[i])) items[items.length - 1] += ' ' + lines[i++].trim();
      }
      const tag = ordered ? 'ol' : 'ul';
      out.push(`<${tag}>` + items.map((it) => `<li>${inline(it)}</li>`).join('') + `</${tag}>`);
      continue;
    }
    if (!line.trim()) { flush(); i++; continue; }
    para.push(line.trim());
    i++;
  }
  flush();
  return out.join('\n') + '\n';
}
