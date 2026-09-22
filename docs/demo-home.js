// The hero demo. A Work calendar (read-only) is copied into a Personal one,
// one way; a Work event moves and its copy follows; the mode buttons change
// how much detail the copies carry. Pure DOM, nothing fetched, nothing sent.
// With prefers-reduced-motion the final state is drawn once and left alone.
const START = 9, END = 17;                     // the day column, 9am to 5pm

// The demo's own words, per language, picked from <html lang>. The page around
// it is already translated; these three event titles, the redacted label and
// the clock format are the only strings that live in here.
const WORDS = {
  en: {
    busy: "Busy",
    hour: (h) => (h < 12 ? `${h}am` : h === 12 ? "12pm" : `${h - 12}pm`),
    work: ["Standup", "Design review", "1:1 with Priya", "Vendor call"],
    where: ["Room 4", "Zoom", "Her office", "Teams"],
    own: ["Lunch with Sam", "Gym"], ownWhere: ["Café Rio", ""],
  },
  de: {
    busy: "Belegt",
    hour: (h) => `${h}:00`,
    work: ["Standup", "Design-Review", "1:1 mit Priya", "Gespräch mit Lieferant"],
    where: ["Raum 4", "Zoom", "Ihr Büro", "Teams"],
    own: ["Mittagessen mit Sam", "Sport"], ownWhere: ["Café Rio", ""],
  },
};
const W = WORDS[document.documentElement.lang.slice(0, 2)] || WORDS.en;

// The whole thing sits in a Mac window or a phone, following the page's switch.
function dress() {
  const ios = document.documentElement.dataset.platform === "ios";
  const f = document.getElementById("frame");
  f.classList.toggle("phone", ios); f.classList.toggle("mac", !ios);
}
dress(); document.addEventListener("cm-platform", dress);
const work = document.getElementById("work");
const personal = document.getElementById("personal");
const modes = document.querySelectorAll(".modes button");
let mode = "basics";

const WORK = [
  { id: "standup", title: W.work[0], where: W.where[0], at: 9.5, len: 0.5 },
  { id: "review",  title: W.work[1], where: W.where[1], at: 11,  len: 1 },
  { id: "one",     title: W.work[2], where: W.where[2], at: 14,  len: 0.5 },
];
const OWN = [
  { title: W.own[0], where: W.ownWhere[0], at: 12.5, len: 1 },
  { title: W.own[1], where: W.ownWhere[1], at: 16.5, len: 0.5 },
];
const LATER = { id: "vendor", title: W.work[3], where: W.where[3], at: 15.5, len: 0.5 };

function pct(h) { return ((h - START) / (END - START) * 100).toFixed(2) + "%"; }
function ticks(day) {
  for (let h = START; h < END; h++) {
    const t = document.createElement("div");
    t.className = "tick"; t.style.top = pct(h);
    t.textContent = W.hour(h);
    day.append(t);
  }
}
function event(kind, e) {
  const el = document.createElement("div");
  el.className = `ev ${kind}`;
  el.style.top = `calc(${pct(e.at)} + 1px)`;
  el.style.height = `calc(${(e.len / (END - START) * 100).toFixed(2)}% - 3px)`;
  el.dataset.title = e.title; el.dataset.where = e.where;
  label(el, kind === "copy" ? mode : "full");
  return el;
}
function label(el, m) {
  el.classList.toggle("busy", m === "busy");
  el.innerHTML = "";
  const b = document.createElement("b");
  b.textContent = m === "busy" ? W.busy : el.dataset.title;
  el.append(b);
  if (m === "full" && el.dataset.where) {
    const s = document.createElement("small"); s.textContent = el.dataset.where; el.append(s);
  }
}

ticks(work); ticks(personal);
const workEls = {}, copyEls = {};
for (const e of WORK) { workEls[e.id] = event("work", e); work.append(workEls[e.id]); }
for (const e of OWN) personal.append(event("own", e));
for (const e of WORK) { copyEls[e.id] = event("copy", e); personal.append(copyEls[e.id]); }
workEls.vendor = event("work", LATER); copyEls.vendor = event("copy", LATER);
work.append(workEls.vendor); personal.append(copyEls.vendor);

for (const b of modes) b.addEventListener("click", () => {
  mode = b.dataset.mode;
  for (const x of modes) x.setAttribute("aria-pressed", String(x === b));
  for (const el of Object.values(copyEls)) label(el, mode);
});

const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
function moveTo(el, hour) { el.style.top = `calc(${pct(hour)} + 1px)`; }

async function loop() {
  while (true) {
    // Reset: copies out, the review back at 11, the vendor call not yet booked.
    for (const el of Object.values(copyEls)) el.classList.add("hidden");
    workEls.vendor.classList.add("gone");
    moveTo(workEls.review, 11); moveTo(copyEls.review, 11);
    await sleep(900);
    // The first sync: each copy slides across, one direction.
    for (const id of ["standup", "review", "one"]) { copyEls[id].classList.remove("hidden"); await sleep(420); }
    await sleep(2400);
    // Work moves the review; the copy follows a moment later.
    moveTo(workEls.review, 13); await sleep(800); moveTo(copyEls.review, 13);
    await sleep(2600);
    // Something new lands in Work; it crosses over too.
    workEls.vendor.classList.remove("gone"); await sleep(800); copyEls.vendor.classList.remove("hidden");
    await sleep(3400);
  }
}
if (still) {
  moveTo(workEls.review, 13); moveTo(copyEls.review, 13);   // the end state, drawn once
} else {
  loop();
}
