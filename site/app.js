const topology = document.querySelector('[data-topology]');
const profileValue = document.querySelector('#profile-value');
const decisionValue = document.querySelector('#decision-value');
const caption = document.querySelector('#sim-caption');
const buttons = [...document.querySelectorAll('[data-profile]')];

const states = {
  isolated: {
    decision: 'no route',
    caption: 'Isolated has no GitHub reachability. The request cannot leave the workload\'s materialized network reality.'
  },
  development: {
    decision: 'sandbox egress',
    caption: 'Development can reach GitHub only through the sandbox egress. The workload never chooses that realm.'
  },
  release: {
    decision: 'real WAN',
    caption: 'Release receives a path to the real destination. TLS can stay end-to-end because ZTS does not need to impersonate GitHub.'
  }
};

function selectProfile(profile) {
  const state = states[profile];
  if (!state) return;
  topology.dataset.topology = profile;
  profileValue.textContent = profile;
  decisionValue.textContent = state.decision;
  caption.textContent = state.caption;
  buttons.forEach((button) => {
    button.setAttribute('aria-pressed', String(button.dataset.profile === profile));
  });
}

document.querySelector('.profile-switch')?.addEventListener('click', (event) => {
  const button = event.target.closest('button[data-profile]');
  if (button) selectProfile(button.dataset.profile);
});

const cast = document.querySelector('#cli-cast');
const replay = document.querySelector('#cast-replay');
const castLines = cast ? [...cast.querySelectorAll('.cast-line')] : [];
let castTimers = [];

function showCastImmediately() {
  if (!cast) return;
  cast.classList.remove('playing');
  castLines.forEach((line) => line.classList.remove('shown'));
}

function replayCast() {
  if (!cast) return;
  castTimers.forEach(clearTimeout);
  castTimers = [];

  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    showCastImmediately();
    return;
  }

  cast.classList.add('playing');
  castLines.forEach((line) => line.classList.remove('shown'));

  let delay = 120;
  castLines.forEach((line, index) => {
    const text = line.textContent.trim();
    const step = text.startsWith('$') ? 520 : text === '' ? 120 : 220;
    const timer = setTimeout(() => line.classList.add('shown'), delay);
    castTimers.push(timer);
    delay += step + Math.min(420, Math.max(0, text.length * 4));
    if (index === castLines.length - 1) {
      castTimers.push(setTimeout(() => cast.classList.remove('playing'), delay + 300));
    }
  });
}

replay?.addEventListener('click', replayCast);


// ---------- background: a slow, sparse network ----------
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const canvas = document.createElement('canvas');
  canvas.id = 'net';
  canvas.setAttribute('aria-hidden', 'true');
  document.body.prepend(canvas);
  const ctx = canvas.getContext('2d');
  let w = 0, h = 0, dpr = 1, nodes = [], pulses = [], raf = 0, last = 0;
  const LINK = 160, SPEED = 0.035;
  // Scrolling heats the network up: more packets travel while the reader
  // moves, then it settles back to the idle rhythm.
  let heat = 0;
  window.addEventListener('scroll', () => { heat = 1; }, { passive: true });

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    w = window.innerWidth; h = window.innerHeight;
    canvas.width = Math.floor(w * dpr); canvas.height = Math.floor(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const want = Math.max(36, Math.min(110, Math.round((w * h) / 17000)));
    while (nodes.length < want) nodes.push(spawn());
    nodes.length = want;
  }
  function spawn() {
    const a = Math.random() * Math.PI * 2;
    return { x: Math.random() * w, y: Math.random() * h, vx: Math.cos(a) * SPEED, vy: Math.sin(a) * SPEED };
  }
  function step(dt) {
    for (const n of nodes) {
      n.x += n.vx * dt; n.y += n.vy * dt;
      if (n.x < -20) n.x = w + 20; else if (n.x > w + 20) n.x = -20;
      if (n.y < -20) n.y = h + 20; else if (n.y > h + 20) n.y = -20;
    }
    for (const p of pulses) p.t += dt * (0.0016 + 0.0024 * heat);
    pulses = pulses.filter((p) => p.t < 1);
    heat *= Math.pow(0.9985, dt);
  }
  function draw() {
    ctx.clearRect(0, 0, w, h);
    const edges = [];
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i];
      for (let j = i + 1; j < nodes.length; j++) {
        const b = nodes[j];
        const dx = a.x - b.x, dy = a.y - b.y, d = Math.hypot(dx, dy);
        if (d > LINK) continue;
        const k = 1 - d / LINK;
        ctx.strokeStyle = `rgba(241,239,231,${(0.34 * k).toFixed(3)})`;
        ctx.lineWidth = 1;
        ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
        edges.push([a, b]);
      }
    }
    ctx.fillStyle = 'rgba(241,239,231,0.55)';
    for (const n of nodes) { ctx.beginPath(); ctx.arc(n.x, n.y, 1.7, 0, Math.PI * 2); ctx.fill(); }
    // a few packets travel along existing paths: the route is the authorization
    if (!reduce && edges.length && pulses.length < 3 + Math.round(9 * heat) && Math.random() < 0.008 + 0.12 * heat) {
      const [a, b] = edges[Math.floor(Math.random() * edges.length)];
      pulses.push({ a, b, t: 0 });
    }
    for (const p of pulses) {
      const x = p.a.x + (p.b.x - p.a.x) * p.t, y = p.a.y + (p.b.y - p.a.y) * p.t;
      const g = ctx.createRadialGradient(x, y, 0, x, y, 6);
      g.addColorStop(0, 'rgba(255,105,63,0.8)'); g.addColorStop(1, 'rgba(255,105,63,0)');
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, 6, 0, Math.PI * 2); ctx.fill();
    }
  }
  function frame(ts) {
    raf = 0;
    const dt = Math.min(50, ts - (last || ts)); last = ts;
    step(dt); draw();
    if (!document.hidden) raf = requestAnimationFrame(frame);
  }
  resize();
  window.addEventListener('resize', resize);
  if (reduce) { draw(); return; }
  document.addEventListener('visibilitychange', () => { if (!document.hidden && !raf) { last = 0; raf = requestAnimationFrame(frame); } });
  raf = requestAnimationFrame(frame);
})();
