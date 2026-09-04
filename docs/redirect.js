// The old GitHub Pages address forwards to the live site.
//
// The site moved to calendarmirror.com on 4 September 2026 and is now served
// from our own infrastructure. The App Store listing's marketing URL still
// points at mattbaylor.github.io/cal-mirror/, and the privacy policy URL Apple
// requires is a page under it — so the old address has to keep working, and has
// to land on the *same* page rather than dumping everyone at the front door.
//
// Why JavaScript rather than a real 301: GitHub Pages issues that redirect only
// when it holds the custom domain itself, and calendarmirror.com resolves to our
// edge instead. So there is no server here to redirect from.
//
// This file ships to both origins and is a no-op on the live one — the hostname
// check is what makes one set of files serve correctly in both places.
(function () {
  if (window.location.hostname !== "mattbaylor.github.io") return;

  // Pages serves the site under a repository prefix; the live site serves it at
  // the root. Strip the prefix so /cal-mirror/privacy.html becomes
  // /privacy.html rather than a 404 with an apologetic tone.
  var prefix = "/cal-mirror";
  var path = window.location.pathname;
  if (path.indexOf(prefix) === 0) path = path.slice(prefix.length);
  if (path === "") path = "/";

  // replace() rather than assign(): the old address should not sit in history,
  // or Back from the new site bounces straight forward again.
  window.location.replace(
    "https://calendarmirror.com" + path + window.location.search + window.location.hash
  );
})();
