// Theme toggle. Enhancement only: prefers-color-scheme already delivers both
// themes with JavaScript disabled, and the button stays hidden until this
// module can actually make it work.
//
// The <head> of every page carries a three-line inline bootstrap that applies
// the stored choice before first paint; this file owns the control itself.

const KEY = 'mosis-theme';
const root = document.documentElement;
const media = window.matchMedia('(prefers-color-scheme: light)');

function stored() {
  try {
    const v = localStorage.getItem(KEY);
    return v === 'light' || v === 'dark' ? v : null;
  } catch {
    return null;
  }
}

function active() {
  return root.getAttribute('data-theme') || (media.matches ? 'light' : 'dark');
}

function apply(theme) {
  root.setAttribute('data-theme', theme);
  try {
    localStorage.setItem(KEY, theme);
  } catch {
    /* private mode: the theme still applies for this page view */
  }
  paint(theme);
}

function paint(theme) {
  const next = theme === 'light' ? 'dark' : 'light';
  for (const btn of document.querySelectorAll('.theme-toggle')) {
    btn.hidden = false;
    btn.setAttribute('aria-label', `Switch to ${next} theme`);
    const text = btn.querySelector('.theme-toggle__text');
    if (text) text.textContent = next;
  }
}

// Follow the OS until the reader states a preference of their own.
media.addEventListener('change', () => {
  if (!stored()) paint(active());
});

document.addEventListener('click', (e) => {
  const btn = e.target.closest?.('.theme-toggle');
  if (!btn) return;
  apply(active() === 'light' ? 'dark' : 'light');
});

paint(active());
