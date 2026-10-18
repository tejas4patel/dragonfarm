// Small client-side helpers for the dragonfarm app.
(function () {
  // "1 Documents" -> a numbered step badge and a label, so the navbar reads
  // as a stepper. Titles without a leading number are left as text.
  function setTitle(link, title) {
    var m = /^(\d+)\s+(.*)$/.exec(title);
    if (!m) { link.textContent = title; return; }
    link.innerHTML = "";
    var n = document.createElement("span"); n.className = "df-step-n"; n.textContent = m[1];
    var t = document.createElement("span"); t.className = "df-step-t"; t.textContent = m[2];
    // The space keeps the accessible name "3 Train" rather than "3Train";
    // the flex layout ignores it visually.
    link.appendChild(n); link.appendChild(document.createTextNode(" ")); link.appendChild(t);
    link.setAttribute("title", m[2]);
  }

  // The navbar list is a tab list, so screen readers expect only tabs in it.
  // Move the hardware badge and the dark-mode switch out, just after it.
  function moveExtras() {
    var nav = document.getElementById("nav");
    if (!nav || nav.parentNode.querySelector(".df-nav-extras")) return;
    var box = document.createElement("div"); box.className = "df-nav-extras";
    Array.prototype.slice.call(nav.children).forEach(function (li) {
      if (li.querySelector("a[data-value]")) return;
      if (li.classList.contains("bslib-nav-spacer")) { li.remove(); return; }
      while (li.firstChild) box.appendChild(li.firstChild);
      li.remove();
    });
    nav.parentNode.insertBefore(box, nav.nextSibling);
  }

  function decorate() {
    document.querySelectorAll("#nav a[data-value]").forEach(function (link) {
      if (!link.querySelector(".df-step-n")) setTitle(link, link.textContent.trim());
    });
    moveExtras();
  }
  if (document.readyState !== "loading") decorate();
  else document.addEventListener("DOMContentLoaded", decorate);

  // Renumber navbar tabs when the route changes (documents first, or table
  // first): {value: "1 Documents", ...} keyed by each nav_panel's value.
  Shiny.addCustomMessageHandler("df-tab-titles", function (titles) {
    Object.keys(titles).forEach(function (value) {
      var link = document.querySelector('#nav a[data-value="' + value + '"]');
      if (link) setTitle(link, titles[value]);
    });
  });
})();
