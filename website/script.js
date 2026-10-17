(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const smooth = (v) => { v = clamp(v); return v * v * (3 - 2 * v); };
  const easeInOut = (v) => { v = clamp(v); return v < .5 ? 4 * v * v * v : 1 - Math.pow(-2 * v + 2, 3) / 2; };
  const lerp = (a, b, t) => a + (b - a) * t;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

  /* ---------- Typo wall ---------- */
  const fixes = [
    ['definately', 'definitely', 'Spelling'],
    ['welocme', 'welcome', 'Swapped letters'],
    ['thats', 'that’s', 'Apostrophes'],
    ['Ho ware you', 'How are you', 'Misplaced space'],
    ['recieve', 'receive', 'Spelling'],
    ['agre with', 'agree with', 'Next-word context'],
    ['github.com/cappy', null, 'Left alone'],
    ['tiink', 'think', 'Neighbouring key'],
    ['youre', 'you’re', 'Apostrophes'],
    ['What ar you doing', 'What are you doing', 'Phrase repair'],
    ['seperate', 'separate', 'Spelling'],
    ['lets go', 'Let’s go', 'Sentence start'],
    ['sam@mail.com', null, 'Left alone'],
    ['defitnetaly', 'definitely', 'Way off'],
    ['Can yu send it', 'Can you send it', 'Phrase repair'],
    ['hello chat', 'Hello chat', 'Capitalisation'],
    ['whats', 'what’s', 'Apostrophes'],
    ['aggree', 'agree', 'Double letters'],
    ['your returning', 'you’re returning', 'Suggestion'],
    ['~/Documents', null, 'Left alone'],
    ['so lets go', 'so let’s go', 'Context'],
    ['dont worry', 'Don’t worry', 'Apostrophes'],
    ['camelCase', null, 'Left alone'],
    ['their arriving', 'they’re arriving', 'Grammar'],
  ];
  const card = ([from, to, label]) => `
    <div class="wall-item">
      <div class="wall-card${to ? '' : ' is-protected'}">
        <span class="from">${from}</span>
        ${to ? `<svg aria-hidden="true"><use href="#arrow"/></svg><span class="to">${to}</span>` : '<span class="shield">unchanged</span>'}
      </div>
      <span class="wall-label">${label}</span>
    </div>`;
  $$('.wall-row').forEach((row, i) => {
    const items = fixes.filter((_, j) => j % 3 === i).map(card).join('');
    row.innerHTML = items + items; // doubled for a seamless loop
    row.lastElementChild && [...row.children].slice(row.children.length / 2).forEach((el) => el.setAttribute('aria-hidden', 'true'));
  });

  /* ---------- Reveal on scroll ---------- */
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('is-visible'); io.unobserve(e.target); } });
  }, { rootMargin: '0px 0px -10% 0px', threshold: .1 });
  $$('.reveal').forEach((el) => io.observe(el));

  /* ---------- Active nav link ---------- */
  const navLinks = $$('.site-nav a');
  const sections = navLinks.map((a) => $(a.getAttribute('href'))).filter(Boolean);
  const updateNav = () => {
    const y = innerHeight * .4;
    let active = navLinks[0];
    sections.forEach((s, i) => { if (s.getBoundingClientRect().top < y) active = navLinks[i]; });
    navLinks.forEach((a) => a.classList.toggle('is-active', a === active));
  };

  /* ---------- Hero: scroll-driven gather ---------- */
  const hero = $('.home-hero');
  const stage = $('.hero-stage');
  const copy = $('.hero-copy');
  const screenWrap = $('.hero-screen');
  const particles = $$('.hero-particle').map((el, i) => ({
    el, i,
    target: el.dataset.target ? $(el.dataset.target) : null,
    rot: parseFloat(getComputedStyle(el).getPropertyValue('--r')) || 0,
  }));
  const staticDoc = $('.doc-static');
  const liveDoc = $('.doc-live');
  let motion = false;
  let progress = 0;

  const motionAllowed = () => !reducedMotion.matches && innerWidth > 760 && innerHeight > 560;

  function setMotion() {
    motion = motionAllowed();
    hero.dataset.motion = String(motion);
    if (!motion) {
      [copy, screenWrap, ...particles.map((p) => p.el), ...$$('.target')].forEach((el) => {
        el.style.opacity = ''; el.style.transform = ''; el.style.filter = '';
      });
      staticDoc.style.opacity = ''; liveDoc.style.opacity = '';
    }
  }

  function heroFrame() {
    if (!motion) return;
    const rect = hero.getBoundingClientRect();
    const span = hero.offsetHeight - innerHeight;
    progress = clamp(-rect.top / span);
    const p = progress;

    // Copy dissolves upward
    const c = smooth(p / .22);
    copy.style.opacity = String(1 - c);
    copy.style.transform = `translateY(${-60 * c}px) scale(${1 - .04 * c})`;
    copy.style.filter = c > 0 ? `blur(${6 * c}px)` : '';
    copy.style.pointerEvents = c > .5 ? 'none' : '';

    // Screen fades and settles
    const s = easeInOut((p - .06) / .42);
    screenWrap.style.opacity = String(smooth((p - .1) / .22));
    screenWrap.style.transform = `scale(${lerp(.88, 1, s)})`;

    // Measure (reads), then move particles (writes)
    const stageRect = stage.getBoundingClientRect();
    const screenRect = $('.screen').getBoundingClientRect();
    const plans = particles.map((pt) => {
      const t = easeInOut((p - .03 - pt.i * .014) / .46);
      const w = pt.el.offsetWidth, h = pt.el.offsetHeight;
      const sx = pt.el.offsetLeft, sy = pt.el.offsetTop; // centre (translate -50%)
      let tx, ty, ts;
      if (pt.target) {
        const r = pt.target.getBoundingClientRect();
        tx = r.left + r.width / 2 - stageRect.left;
        ty = r.top + r.height / 2 - stageRect.top;
        ts = Math.min(r.width / w, r.height / h * 1.2);
      } else {
        tx = screenRect.left + screenRect.width / 2 - stageRect.left;
        ty = screenRect.top + screenRect.height * .45 - stageRect.top;
        ts = .35;
      }
      return { pt, t, dx: (tx - sx) * t, dy: (ty - sy) * t, sc: lerp(1, ts, t) };
    });
    plans.forEach(({ pt, t, dx, dy, sc }) => {
      pt.el.style.transform = `translate(${dx}px, ${dy}px) rotate(${-pt.rot * t}deg) scale(${sc})`;
      const fade = pt.target ? smooth((t - .82) / .18) : smooth((t - .3) / .55);
      pt.el.style.opacity = String(1 - fade);
      pt.el.style.pointerEvents = t > .02 ? 'none' : '';
      if (pt.target) pt.target.style.opacity = String(smooth((t - .78) / .2));
    });

    // Static frame hands over to the live demo once everything has landed
    const live = smooth((p - .66) / .06);
    staticDoc.style.opacity = String(1 - live);
    liveDoc.style.opacity = String(live);
    const capsuleT = $('#t-capsule');
    if (live > 0) capsuleT.style.opacity = String(1 - live);
    demo.want(live > .5);

    hero.toggleAttribute('data-in-view', rect.bottom > 0 && rect.top < innerHeight);
    document.body.classList.toggle('past-intro', p > .15);
  }

  /* ---------- Live typing demo ---------- */
  const demo = (() => {
    const body = $('.window-body');
    const capsule = $('.live-capsule');
    let running = false, wanted = false, token = 0, hideTimer = 0;

    const caret = () => { const c = document.createElement('span'); c.className = 'caret'; return c; };
    let car = caret();

    function newLine() {
      const p = document.createElement('p');
      car.remove(); p.appendChild(car); liveDoc.appendChild(p);
      return p;
    }
    async function type(line, text, my) {
      for (const ch of text) {
        if (my !== token) throw 0;
        line.insertBefore(document.createTextNode(ch), car);
        line.normalize();
        await sleep(ch === ' ' ? 90 : 48 + Math.random() * 55);
      }
    }
    function placeCapsule(word) {
      const scale = body.getBoundingClientRect().width / body.offsetWidth || 1;
      const b = body.getBoundingClientRect(), w = word.getBoundingClientRect();
      capsule.style.left = `${(w.left - b.left) / scale - 12}px`;
      capsule.style.top = `${(w.bottom - b.top) / scale + 6}px`;
    }
    function showCapsule(word, html, ms) {
      clearTimeout(hideTimer);
      capsule.innerHTML = html;
      placeCapsule(word);
      capsule.classList.add('is-on');
      if (ms) hideTimer = setTimeout(() => capsule.classList.remove('is-on'), ms);
    }
    // Types `src`, then `trigger`, then applies the correction.
    async function word(line, src, fix, trigger, my, mode = 'auto') {
      const w = document.createElement('span');
      w.className = 'word';
      line.insertBefore(w, car);
      for (const ch of src) {
        if (my !== token) throw 0;
        w.textContent += ch;
        await sleep(48 + Math.random() * 55);
      }
      await type(line, trigger, my);
      await sleep(mode === 'auto' ? 160 : 220);
      if (my !== token) throw 0;
      if (mode === 'auto') {
        w.textContent = fix;
        w.classList.add('is-fresh');
        requestAnimationFrame(() => requestAnimationFrame(() => w.classList.remove('is-fresh')));
        showCapsule(w, `<span class="cap-word">${fix}</span><span class="cap-sep"></span><span class="cap-btn">Undo</span>`, 2500);
      } else {
        w.classList.add('is-sugg');
        showCapsule(w, `<span class="cap-word">${fix}</span><span class="cap-sep"></span><span class="keycap keycap-sm">tab</span>`);
        await sleep(1300);
        if (my !== token) throw 0;
        const key = $('.keycap', capsule);
        key && key.classList.add('is-pressed');
        await sleep(220);
        w.classList.remove('is-sugg');
        w.textContent = fix;
        w.classList.add('is-fresh');
        requestAnimationFrame(() => requestAnimationFrame(() => w.classList.remove('is-fresh')));
        await sleep(200);
        capsule.classList.remove('is-on');
      }
    }

    async function loop() {
      const my = ++token;
      running = true;
      try {
        while (my === token) {
          liveDoc.innerHTML = '';
          capsule.classList.remove('is-on');
          car = caret();
          await sleep(500);
          let l = newLine();
          await word(l, 'hello', 'Hello', ' ', my);
          await type(l, 'chat ', my);
          await word(l, 'welocme', 'welcome', ' ', my);
          await sleep(500);
          l = newLine();
          await type(l, 'I ', my);
          await word(l, 'definately', 'definitely', ' ', my);
          await type(l, 'agree', my);
          await sleep(900);
          l = newLine();
          await word(l, 'Ho ware', 'How are', ' you ', my);
          await type(l, 'doing?', my);
          await sleep(900);
          l = newLine();
          await type(l, 'I think ', my);
          await word(l, 'your', 'you’re', ' returning ', my, 'suggest');
          await type(l, 'tomorrow', my);
          await sleep(700);
          l = newLine();
          await word(l, 'dont', 'Don’t', ' ', my);
          await type(l, 'worry about it', my);
          await sleep(3200);
        }
      } catch (_) { /* cancelled */ }
    }
    function want(on) {
      if (on === wanted) return;
      wanted = on;
      if (on && !running) loop();
      if (!on) { token++; running = false; clearTimeout(hideTimer); capsule.classList.remove('is-on'); }
    }
    return { want };
  })();

  /* ---------- Wiring ---------- */
  let ticking = false;
  const onScroll = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => { ticking = false; heroFrame(); updateNav(); if (!motion) document.body.classList.toggle('past-intro', scrollY > 300); });
  };
  const onResize = () => { setMotion(); onScroll(); };

  setMotion();
  addEventListener('scroll', onScroll, { passive: true });
  addEventListener('resize', onResize);
  reducedMotion.addEventListener?.('change', onResize);
  document.fonts?.ready.then(onScroll);
  onScroll();

  // Without the pinned hero, run the demo whenever the screen is visible.
  new IntersectionObserver(([e]) => {
    if (motion) return;
    staticDoc.style.opacity = e.isIntersecting && !reducedMotion.matches ? '0' : '';
    liveDoc.style.opacity = e.isIntersecting && !reducedMotion.matches ? '1' : '';
    demo.want(e.isIntersecting && !reducedMotion.matches);
  }, { threshold: .4 }).observe($('.screen'));
})();
