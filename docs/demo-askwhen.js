// The hero demo: two devices and the wire between them. Dana's device works
// out three gaps; only those cross to the page on Alex's device; Alex picks
// one; the request crosses back; Dana accepts; the answer crosses again.
// Pure DOM, nothing fetched. Under reduced motion the accepted state is drawn once.
const START = 9, END = 18, LEN = 1;
const device = document.getElementById("device");
const times = document.getElementById("times");
const request = document.getElementById("request");
const cursor = document.getElementById("cursor");
const status = document.getElementById("status");
const packet = document.getElementById("packet");
const wireLabel = document.getElementById("wire-label");
const pct = (h) => ((h - START) / (END - START) * 100).toFixed(2) + "%";

// Each device is a phone or a Mac window, following the page's switch.
function dress() {
  const ios = document.documentElement.dataset.platform === "ios";
  for (const id of ["frame-a", "frame-b"]) {
    const f = document.getElementById(id);
    f.classList.toggle("phone", ios); f.classList.toggle("mac", !ios);
  }
}
dress(); document.addEventListener("cm-platform", dress);

for (let h = START; h < END; h++) {
  const t = document.createElement("div"); t.className = "tick"; t.style.top = pct(h);
  t.textContent = h < 12 ? `${h}am` : h === 12 ? "12pm" : `${h - 12}pm`; device.append(t);
}
function block(cls, text, at, len) {
  const el = document.createElement("div"); el.className = `ev ${cls}`;
  el.style.top = `calc(${pct(at)} + 1px)`; el.style.height = `calc(${(len / (END - START) * 100).toFixed(2)}% - 3px)`;
  el.textContent = text; device.append(el); return el;
}
block("own", "Standup", 9.5, 0.5); block("own", "Grant review", 11, 1); block("own", "Lunch", 12.5, 1); block("own", "Pick up Sam", 15.5, 1);
const OFFERS = [[10, "10:00 AM"], [14, "2:00 PM"], [16.5, "4:30 PM"]];
const offers = OFFERS.map(([at, label]) => block("offer", `Offered, ${label.replace(" ", "\u00a0")}`, at, LEN));
const booked = block("booked", "Alex Rivera, coffee", 14, LEN); booked.classList.add("hidden");
const chips = OFFERS.map(([, label]) => { const s = document.createElement("span"); s.textContent = `Tuesday, ${label}`; times.append(s); return s; });
const pick = chips[1];

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
function say(cls, head, body) { status.className = `status ${cls}`; status.innerHTML = `<b>${head}</b>${body}`; }
// Something crosses the wire: from Dana's device to Alex's ("b") or back ("a").
async function cross(to, label) {
  packet.classList.remove("on"); packet.classList.toggle("to-b", to !== "b");
  packet.style.left = to === "b" ? "0%" : "100%";
  await sleep(60); packet.classList.add("on"); wireLabel.textContent = label; wireLabel.classList.add("on");
  await sleep(60); packet.style.left = to === "b" ? "100%" : "0%"; packet.classList.toggle("to-b", to === "b");
  await sleep(1000); packet.classList.remove("on"); wireLabel.classList.remove("on");
}

async function loop() {
  while (true) {
    for (const o of offers) o.classList.add("hidden");
    for (const c of chips) c.classList.add("hidden"); pick.classList.remove("picked");
    booked.classList.add("hidden"); request.classList.add("hidden"); request.classList.remove("pressed");
    cursor.classList.remove("on"); status.classList.add("hidden");
    await sleep(900);
    for (const o of offers) { o.classList.remove("hidden"); await sleep(260); }   // the device chooses
    await sleep(700);
    await cross("b", "3 times, nothing else");                                   // only those go up
    for (const c of chips) { c.classList.remove("hidden"); await sleep(220); }
    await sleep(1300);
    const r = pick.getBoundingClientRect(), pr = pick.offsetParent.getBoundingClientRect();   // Alex picks 2:00
    cursor.style.left = "70%"; cursor.style.top = "20%"; cursor.classList.add("on"); await sleep(300);
    cursor.style.left = `${(r.left - pr.left + r.width * .5) / pr.width * 100}%`;
    cursor.style.top = `${(r.top - pr.top + r.height * .5) / pr.height * 100}%`;
    await sleep(900); pick.classList.add("picked"); await sleep(400); cursor.classList.remove("on");
    say("", "Asked. Check your email to confirm.", " Held for 15 minutes; nothing reaches Dana until you do.");
    status.classList.remove("hidden");
    await sleep(1400);
    await cross("a", "one request");                                             // back to Dana
    request.classList.remove("hidden");
    await sleep(2200);
    request.classList.add("pressed"); await sleep(350);                          // Dana accepts
    request.classList.add("hidden"); offers[1].classList.add("hidden"); booked.classList.remove("hidden");
    await sleep(400);
    await cross("b", "accepted");
    say("ok", "Dana said yes.", " Tuesday at 2:00 PM is on her calendar, and an invitation is on its way to you.");
    await sleep(3600);
  }
}
if (matchMedia("(prefers-reduced-motion: reduce)").matches) {
  offers[1].classList.add("hidden"); booked.classList.remove("hidden"); pick.classList.add("picked");
  say("ok", "Dana said yes.", " Tuesday at 2:00 PM is on her calendar, and an invitation is on its way to you.");
} else {
  loop();
}
