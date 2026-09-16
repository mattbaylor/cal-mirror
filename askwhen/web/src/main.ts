import './components/request-page.ts';
import type { RequestPage } from './components/request-page.ts';
import { loadDump, slugFromLocation } from './dump.ts';
import { LINK_GONE } from './service.ts';

async function mount() {
  const page = document.createElement('request-page') as RequestPage;
  const slug = slugFromLocation();
  const result = await loadDump(slug);
  if (result === LINK_GONE) {
    page.linkGone = true;
  } else {
    page.dump = result;
    // Through a personal link, the URL's segment is the code, not the slug;
    // it goes back with the request so the service can spend it.
    if (result?.personal) page.code = slug;
  }
  const app = document.getElementById('app');
  if (!app) return;
  app.replaceChildren(page);
  app.removeAttribute('aria-busy');
}

mount();
