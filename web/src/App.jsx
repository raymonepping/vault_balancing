// App.jsx: the shell (vault_codex). Frosted rail, floating topbar, the pages
// as hash routes, ←/→ between pages, ? for the shortcuts, and the "Vault
// said" drawer with every site's raw answers. Read-only: no button here
// changes Vault or HAProxy itself: a signed-in operator's button runs the
// drill step's make target on the host (D16).
import { useCallback, useEffect, useState } from 'react';
import { Map, Network, ListOrdered, FileText, Layers3, ScrollText, ExternalLink, PanelLeftClose, PanelLeftOpen, Keyboard } from 'lucide-react';
import { useRoute, useResource } from './hooks.js';
import { useSituation } from './useSituation.js';
import { NAMES, MAP_ORDER } from './situation.js';
import { Drawer, Mono } from './components/ui.jsx';
import Footer from './components/Footer.jsx';
import Person from './components/Person.jsx';
import Situation from './pages/Situation.jsx';
import Replication from './pages/Replication.jsx';
import Timeline from './pages/Timeline.jsx';
import Report from './pages/Report.jsx';
import Layers from './pages/Layers.jsx';

export const PAGES = [
  { id: 'room', label: 'Situation room', title: 'The situation room', icon: Map, Page: Situation },
  { id: 'replication', label: 'Replication', title: 'Replication', icon: Network, Page: Replication },
  { id: 'timeline', label: 'Drill timeline', title: 'Drill timeline', icon: ListOrdered, Page: Timeline },
  { id: 'report', label: 'Report', title: 'The report', icon: FileText, Page: Report },
  { id: 'layers', label: 'Layers', title: 'How the house was built', icon: Layers3, Page: Layers },
];

function Brand() {
  return (
    <svg className="brand-icon" viewBox="0 0 32 32" aria-hidden="true" focusable="false">
      <path d="M16 2l12 7v14l-12 7-12-7V9z" fill="currentColor" />
      <path d="M9 17h14M16 10v14" stroke="#fff" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  );
}

const FOLD_KEY = 'vbal.sidebar.collapsed';
const readFolded = () => {
  try {
    return window.localStorage.getItem(FOLD_KEY) === '1';
  } catch {
    return false;
  }
};
const writeFolded = (v) => {
  try {
    window.localStorage.setItem(FOLD_KEY, v ? '1' : '0');
  } catch {
    /* not remembered, still works */
  }
};

function NavLinks({ route, className, folded = false }) {
  return PAGES.map(({ id, label, icon: Icon }) => (
    <a key={id} href={`#/${id}`} className={`${className}${route === id ? ' active' : ''}`} aria-current={route === id ? 'page' : undefined} title={folded ? label : undefined}>
      <span className="nav-icon">
        <Icon aria-hidden="true" />
      </span>
      <span className="nav-label">{label}</span>
    </a>
  ));
}

// The topbar's one-line state: which site is primary, as Vault reports it.
function PrimaryPill({ s }) {
  const primaries = s.sites.filter((x) => x.state === 'up' && x.data?.role === 'primary');
  // Before the first snapshot only: while the stream reconnects, the last
  // state stays (the page says it is reconnecting).
  const waiting = !s.connected && s.sites.length === 0;
  const state = waiting ? 'unknown' : s.split_brain ? 'critical' : primaries.length === 1 ? 'healthy' : 'critical';
  const text = waiting ? 'connecting…' : s.split_brain ? 'two primaries' : primaries.length === 1 ? `primary: ${NAMES[primaries[0].site]}` : 'no primary';
  return (
    <span className={`cluster-pill ${state}`} role="status" aria-live="polite">
      <span className={`cluster-dot${state === 'healthy' ? ' live' : ''}`} aria-hidden="true" />
      <span className="cluster-label">{text}</span>
    </span>
  );
}

function useKeys(route, onHelp) {
  useEffect(() => {
    const onKey = (e) => {
      const t = e.target;
      if (t instanceof HTMLElement && (t.closest('input, textarea, select, [contenteditable="true"]') || t.closest('dialog[open], .vg-drawer'))) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const current = window.location.hash.replace(/^#\/?/, '').split('?')[0] || route;
      const i = Math.max(0, PAGES.findIndex((p) => p.id === current));
      if (e.key === 'ArrowRight' && i < PAGES.length - 1) window.location.hash = `#/${PAGES[i + 1].id}`;
      else if (e.key === 'ArrowLeft' && i > 0) window.location.hash = `#/${PAGES[i - 1].id}`;
      else if (e.key === '?') onHelp();
      else return;
      e.preventDefault();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [route, onHelp]);
}

// Every site's raw answers: what the console's words were built from.
function VaultSaid({ s }) {
  const byId = Object.fromEntries(s.sites.map((x) => [x.site, x]));
  return (
    <ol className="said-list">
      {MAP_ORDER.map((id) => {
        const site = byId[id];
        return (
          <li key={id} className="said-item">
            <div className="said-head">
              <strong>{NAMES[id]}</strong>
              <span className={`said-status ${site?.state === 'up' ? 'ok' : 'bad'}`}>{site?.state ?? 'unknown'}</span>
            </div>
            <Mono>GET sys/replication/status, GET sys/health (no token)</Mono>
            <pre className="said-json">{JSON.stringify({ replication: site?.data?.vault_said?.replication ?? null, health: (site?.data?.nodes ?? []).map((n) => ({ node: n.node, ...n.said })) }, null, 2)}</pre>
          </li>
        );
      })}
    </ol>
  );
}

export default function App() {
  const route = useRoute(PAGES.map((p) => p.id), 'room');
  const page = PAGES.find((p) => p.id === route);
  const s = useSituation();
  const me = useResource('/api/me');
  const [drawer, setDrawer] = useState(false);
  const [help, setHelp] = useState(false);
  const [folded, setFolded] = useState(readFolded);
  const onHelp = useCallback(() => setHelp(true), []);
  useKeys(route, onHelp);
  useEffect(() => {
    document.title = `${page.title}: When a Site Dies`;
  }, [page]);
  const toggleFold = () =>
    setFolded((f) => {
      writeFolded(!f);
      return !f;
    });

  return (
    <div className="vg-shell">
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <aside className={`vg-sidebar${folded ? ' collapsed' : ''}`} aria-label="Pages">
        <div className="sidebar-brand">
          <Brand />
          <span className="brand-name">When a Site Dies</span>
        </div>
        <nav className="sidebar-nav" id="rail-nav">
          <NavLinks route={route} className="nav-item" folded={folded} />
        </nav>
        <div className="sidebar-footer">
          <button type="button" className="sidebar-toggle" onClick={toggleFold} aria-expanded={!folded} aria-controls="rail-nav" title={folded ? 'Expand the sidebar' : 'Collapse the sidebar'}>
            {folded ? <PanelLeftOpen aria-hidden="true" /> : <PanelLeftClose aria-hidden="true" />}
            <span className="sr-only">{folded ? 'Expand the sidebar' : 'Collapse the sidebar'}</span>
          </button>
          <p className="sidebar-note">Vault Enterprise 2.2, vault_balancing</p>
        </div>
      </aside>

      <div className="vg-main">
        <div className="topbar-wrap">
          <header className="vg-topbar">
            <div className="topbar-left">
              <h1 className="page-title">{page.title}</h1>
            </div>
            <div className="topbar-right">
              <PrimaryPill s={s} />
              <Person me={me.data} />
              <button type="button" className="vault-link said-button" onClick={() => setDrawer(true)}>
                <ScrollText aria-hidden="true" />
                <span className="link-label">Vault said</span>
              </button>
              <button type="button" className="vault-link said-button" onClick={onHelp} aria-label="Keyboard shortcuts">
                <Keyboard aria-hidden="true" />
              </button>
              <a className="vault-link" href="https://localhost:19101/ui/" target="_blank" rel="noreferrer">
                <ExternalLink aria-hidden="true" />
                <span className="link-label">Vault UI</span>
                <span className="sr-only"> (opens in a new tab)</span>
              </a>
            </div>
          </header>
          <nav className="mobile-nav" aria-label="Pages">
            <NavLinks route={route} className="mobile-nav__item" />
          </nav>
        </div>

        <main id="main" className="vg-content" tabIndex={-1}>
          {window.location.hash.includes('signin=failed') && (
            <p className="inline-notice error" role="alert">
              Sign-in did not complete. Try again; make doctor shows whether Keycloak answers.
            </p>
          )}
          <page.Page key={page.id} s={s} me={me.data} />
        </main>
        <Footer />
      </div>

      <Drawer open={drawer} title="Vault said" onClose={() => setDrawer(false)}>
        <p className="drawer-intro">Each site's raw answers, newest: what every word on these pages was built from. Unauthenticated status endpoints only; never a token.</p>
        <VaultSaid s={s} />
      </Drawer>

      <Drawer open={help} title="Keyboard" onClose={() => setHelp(false)}>
        <dl className="facts">
          <dt>
            <kbd>→</kbd>
          </dt>
          <dd>next page</dd>
          <dt>
            <kbd>←</kbd>
          </dt>
          <dd>previous page</dd>
          <dt>
            <kbd>?</kbd>
          </dt>
          <dd>this list</dd>
          <dt>
            <kbd>Esc</kbd>
          </dt>
          <dd>close a drawer</dd>
        </dl>
      </Drawer>
    </div>
  );
}
