// Capability-matrix filtering.
//
// The whole table is in the HTML — this file never renders a cell. Platform
// toggles are checkboxes driven by CSS below, so they already work without
// script; what this adds is the capability search and the live count, and
// those controls stay hidden until it runs.

const table = document.querySelector('.matrix');
if (table) {
  const rows = [...table.querySelectorAll('tbody tr')];
  const cols = [...document.querySelectorAll('.colfilter')];
  const search = document.querySelector('#cap-search');
  const searchBox = document.querySelector('.matrix-search');
  const count = document.querySelector('.matrix-count');
  const empty = document.querySelector('.matrix-empty');

  function applyRows() {
    const q = (search?.value || '').trim().toLowerCase();
    let shown = 0;
    for (const row of rows) {
      const hit = !q || row.dataset.cap.includes(q);
      row.hidden = !hit;
      if (hit) shown++;
    }
    return shown;
  }

  function update() {
    const shownRows = applyRows();
    const shownCols = cols.filter((c) => c.checked).length;
    if (count) {
      count.hidden = false;
      count.textContent = `${shownRows * shownCols} of ${rows.length * cols.length} cells`;
    }
    if (empty) empty.hidden = shownRows > 0;
  }

  if (searchBox) searchBox.hidden = false;
  search?.addEventListener('input', update);
  for (const box of cols) box.addEventListener('change', update);
  update();
}
