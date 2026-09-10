import './components/request-page.ts';
import type { RequestPage } from './components/request-page.ts';
import { loadDump, slugFromLocation } from './dump.ts';

async function mount() {
  const page = document.createElement('request-page') as RequestPage;
  page.dump = await loadDump(slugFromLocation());
  const app = document.getElementById('app');
  if (!app) return;
  app.replaceChildren(page);
  app.removeAttribute('aria-busy');
}

mount();
