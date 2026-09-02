import './components/request-page.js';
import { loadDump, slugFromLocation } from './dump.js';

async function mount() {
  const page = document.createElement('request-page');
  page.dump = await loadDump(slugFromLocation());
  const app = document.getElementById('app');
  app.replaceChildren(page);
  app.removeAttribute('aria-busy');
}

mount();
