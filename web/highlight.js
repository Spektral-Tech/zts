// Build-time syntax highlighting for the two languages the site shows: shell
// sessions and YAML. Small on purpose; output is HTML with tok-* classes.
// A prompt is rendered as an empty span and drawn by CSS, so copying a block
// never picks up the "$ ".
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const tok = (cls, s) => `<span class="tok-${cls}">${esc(s)}</span>`;

export function hlShell(src) {
  return src.split('\n').map((line) => {
    let out = '';
    let rest = line;
    const m = /^(\s*)\$ /.exec(rest);
    if (m) { out += esc(m[1]) + '<span class="prompt"></span>'; rest = rest.slice(m[0].length); }
    let first = !m ? false : true; // the first word after a prompt is the command
    const continued = /^\s+/.test(rest) && !m;
    if (continued) first = false;
    const re = /(#.*$)|("(?:[^"\\]|\\.)*"|'[^']*')|(\s+)|(\\$)|(\|\||&&|\||;)|(--?[A-Za-z][\w-]*)|([^\s"'|;&\\]+)/g;
    let x;
    let expectCmd = first;
    while ((x = re.exec(rest))) {
      const [, cmt, str, ws, cont, op, flag, word] = x;
      if (cmt) out += tok('cmt', cmt);
      else if (str) { out += tok('str', str); expectCmd = false; }
      else if (ws) out += esc(ws);
      else if (cont) out += tok('cont', cont);
      else if (op) { out += tok('op', op); expectCmd = true; }
      else if (flag) { out += tok('flag', flag); expectCmd = false; }
      else if (word) {
        if (expectCmd || word === 'sudo') { out += tok('cmd', word); expectCmd = word === 'sudo'; }
        else out += esc(word);
      }
    }
    return out;
  }).join('\n');
}

export function hlYaml(src) {
  return src.split('\n').map((line) => {
    let out = '';
    let rest = line;
    const c = rest.indexOf('#');
    let comment = '';
    if (c >= 0 && /^\s*#/.test(rest.slice(0, c + 1)) === false ? c >= 0 && /(^|\s)#/.test(rest) : c >= 0) {
      const idx = rest.search(/(^|\s)#/);
      if (idx >= 0) { comment = rest.slice(idx); rest = rest.slice(0, idx); }
    }
    const key = /^(\s*)(- )?([\w.\-*"']+)(:)(\s|$)/.exec(rest);
    if (key) {
      out += esc(key[1]) + (key[2] ? tok('op', key[2]) : '') + tok('key', key[3]) + tok('op', ':') + esc(key[5]);
      rest = rest.slice(key[0].length);
    } else {
      const dash = /^(\s*)(- )/.exec(rest);
      if (dash) { out += esc(dash[1]) + tok('op', '- '); rest = rest.slice(dash[0].length); }
    }
    // values: flow mappings/sequences, strings, numbers, booleans, inner keys
    const re = /("(?:[^"\\]|\\.)*"|'[^']*')|(\{|\}|\[|\]|,)|(\b(?:true|false|null)\b)|(\b\d+(?:\.\d+)*(?:\/\d+)?\b)|([\w.\-*]+)(:)(?=\s|$)|(\s+)|([^\s{}\[\],"']+)/g;
    let x;
    while ((x = re.exec(rest))) {
      const [, str, punct, bool, num, ikey, colon, ws, word] = x;
      if (str) out += tok('str', str);
      else if (punct) out += tok('op', punct);
      else if (bool) out += tok('num', bool);
      else if (num) out += tok('num', num);
      else if (ikey) out += tok('key', ikey) + tok('op', colon);
      else if (ws) out += esc(ws);
      else if (word) out += esc(word);
    }
    if (comment) out += tok('cmt', comment);
    return out;
  }).join('\n');
}

export function highlight(lang, src) {
  if (lang === 'yaml' || lang === 'yml') return hlYaml(src);
  if (lang === 'bash' || lang === 'sh' || lang === 'shell' || lang === 'console') return hlShell(src);
  return esc(src);
}
