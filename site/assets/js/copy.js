// Copy buttons for command blocks.
//
// Every command is plain selectable text in a <pre> first; this only saves a
// drag. The button ships hidden and is revealed here, and only when the
// clipboard API is actually available — a button that silently fails is worse
// than no button.

if (navigator.clipboard?.writeText) {
  for (const block of document.querySelectorAll('.codeblock')) {
    const btn = block.querySelector('.copy');
    const code = block.querySelector('code');
    if (!btn || !code) continue;

    btn.hidden = false;
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(code.innerText.trim());
        btn.dataset.done = '';
        btn.textContent = 'copied';
      } catch {
        // Denied permission or an insecure origin: say so rather than lie.
        btn.textContent = 'select it';
      }
      setTimeout(() => {
        delete btn.dataset.done;
        btn.textContent = 'copy';
      }, 1600);
    });
  }
}
