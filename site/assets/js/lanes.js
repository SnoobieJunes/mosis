// Lane rails: send one packet down a rail when it scrolls into view.
//
// Pure decoration. Every rail is a complete divider without this file, so the
// module never renders content and never runs at all when the reader has asked
// for less motion.

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');

function arm() {
  const rails = document.querySelectorAll('.rail');
  if (!rails.length || !('IntersectionObserver' in window)) return;

  const seen = new IntersectionObserver(
    (entries, obs) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        // One packet per rail per page view — a rail that fires on every scroll
        // reads as a loading spinner, not a link.
        entry.target.classList.add('is-live');
        obs.unobserve(entry.target);
      }
    },
    { rootMargin: '0px 0px -8% 0px', threshold: 0 },
  );

  for (const rail of rails) seen.observe(rail);
}

if (!reduced.matches) arm();

// If the reader turns motion back on mid-session, honour it from then on.
reduced.addEventListener('change', (e) => {
  if (!e.matches) arm();
});
