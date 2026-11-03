// App.jsx — the shell: frosted rail, floating topbar, five pages by hash route.
import { useState } from 'react';
import { LayoutGrid, ShieldCheck, Shuffle, Binary, ListChecks, ExternalLink, ScrollText, LogIn, LogOut, UserRound, PanelLeftClose, PanelLeftOpen } from 'lucide-react';
import { useResource, useRoute, useVaultLog } from './hooks.js';
import { AuthContext, Drawer, signInHref } from './components/ui.jsx';
import Footer from './components/Footer.jsx';
import Overview from './pages/Overview.jsx';
import QuantumPki from './pages/QuantumPki.jsx';
import Agility from './pages/Agility.jsx';
import Fpe from './pages/Fpe.jsx';
import Lifecycle from './pages/Lifecycle.jsx';

const PAGES = [
  { id: 'overview', label: 'Overview', title: 'Vault 2.2 crypto lab', icon: LayoutGrid, Page: Overview },
  { id: 'pki', label: 'Quantum PKI', title: 'Quantum PKI', icon: ShieldCheck, Page: QuantumPki },
  { id: 'agility', label: 'Crypto agility', title: 'Crypto agility', icon: Shuffle, Page: Agility },
  { id: 'fpe', label: 'FF1', title: 'Format-preserving encryption', icon: Binary, Page: Fpe },
  { id: 'lifecycle', label: 'Lifecycle', title: 'Certificate lifecycle', icon: ListChecks, Page: Lifecycle },
];

function Brand() {
  return (
    <svg className="brand-icon" viewBox="0 0 32 32" aria-hidden="true" focusable="false">
      <path d="M16 2l12 7v14l-12 7-12-7V9z" fill="currentColor" />
      <path d="M11 13h10M11 17h10M11 21h6" stroke="#fff" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  );
}

// The rail's folded state survives a reload. Browser storage can be missing or
// throw (private windows): then the rail simply starts open.
const FOLD_KEY = 'vcry.sidebar.collapsed';
function readFolded() {
  try {
    return window.localStorage.getItem(FOLD_KEY) === '1';
  } catch {
    return false;
  }
}
function writeFolded(v) {
  try {
    window.localStorage.setItem(FOLD_KEY, v ? '1' : '0');
  } catch {
    /* not remembered, still works */
  }
}

function NavLinks({ route, className, folded = false }) {
  return PAGES.map(({ id, label, icon: Icon }) => (
    <a
      key={id}
      href={`#/${id}`}
      className={`${className}${route === id ? ' active' : ''}`}
      aria-current={route === id ? 'page' : undefined}
      title={folded ? label : undefined}
    >
      <span className="nav-icon">
        <Icon aria-hidden="true" />
      </span>
      <span className="nav-label">{label}</span>
    </a>
  ));
}

function ClusterPill({ health }) {
  const h = health.data;
  const state = health.error ? 'critical' : !h ? 'unknown' : h.ok ? 'healthy' : 'critical';
  const text = health.error ? 'API unreachable' : !h ? 'checking…' : h.ok ? `vault-1 ${h.vault.version}` : h.vault?.sealed ? 'vault-1 sealed' : 'vault-1 not ready';
  return (
    <span className={`cluster-pill ${state}`} role="status" aria-live="polite">
      <span className={`cluster-dot${state === 'healthy' ? ' live' : ''}`} aria-hidden="true" />
      <span className="cluster-label">{text}</span>
    </span>
  );
}

function Person({ me }) {
  const [open, setOpen] = useState(false);
  if (!me) return null;
  if (!me.signedIn) {
    return (
      <a className="primary-button signin-button" href={signInHref()}>
        <LogIn size={14} aria-hidden="true" /> Sign in
      </a>
    );
  }
  return (
    <div className="user-menu">
      <button type="button" className="persona" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        <span className="persona-dot persona-dot--auth" aria-hidden="true" />
        <UserRound size={13} aria-hidden="true" />
        <span>{me.name}</span>
      </button>
      {open && (
        <div className="user-menu-panel" role="dialog" aria-label="Signed in">
          <div className="umf-row umf-user">{me.name}</div>
          <div className="umf-row umf-meta">
            {me.user} · Vault token until {new Date(me.vaultTokenExpires).toLocaleTimeString('en-GB')}
          </div>
          <div className="umf-groups" aria-label="Groups">
            {me.groups.map((g) => (
              <span key={g} className="umf-chip">
                {g}
              </span>
            ))}
          </div>
          <div className="umf-row umf-meta">Vault policies: {me.policies.join(', ') || 'none'}</div>
          <a className="umf-signout" href="/auth/logout">
            <LogOut size={12} aria-hidden="true" /> Sign out
          </a>
        </div>
      )}
    </div>
  );
}

export default function App() {
  const route = useRoute(PAGES.map((p) => p.id), 'overview');
  const page = PAGES.find((p) => p.id === route);
  const health = useResource('health', '/api/health', { intervalMs: 15000 });
  const me = useResource('me', '/api/me');
  const signinFailed = window.location.hash.includes('signin=failed');
  const log = useVaultLog();
  const [drawer, setDrawer] = useState(false);
  const [folded, setFolded] = useState(readFolded);
  const toggleFold = () =>
    setFolded((f) => {
      writeFolded(!f);
      return !f;
    });
  const vaultUi = health.data?.vaultUi || '/ui/';

  return (
    <AuthContext.Provider value={me.data || { signedIn: false }}>
    <div className="vg-shell">
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <aside className={`vg-sidebar${folded ? ' collapsed' : ''}`} aria-label="Rooms">
        <div className="sidebar-brand">
          <Brand />
          <span className="brand-name">Crypto Lab</span>
        </div>
        <nav className="sidebar-nav" id="rail-nav">
          <NavLinks route={route} className="nav-item" folded={folded} />
        </nav>
        <div className="sidebar-footer">
          <button
            type="button"
            className="sidebar-toggle"
            onClick={toggleFold}
            aria-expanded={!folded}
            aria-controls="rail-nav"
            title={folded ? 'Expand the sidebar' : 'Collapse the sidebar'}
          >
            {folded ? <PanelLeftOpen aria-hidden="true" /> : <PanelLeftClose aria-hidden="true" />}
            <span className="sr-only">{folded ? 'Expand the sidebar' : 'Collapse the sidebar'}</span>
          </button>
          <p className="sidebar-note">Vault Enterprise 2.2 · vault_crypto</p>
        </div>
      </aside>

      <div className="vg-main">
        <div className="topbar-wrap">
          <header className="vg-topbar">
            <div className="topbar-left">
              <h1 className="page-title">{page.title}</h1>
            </div>
            <div className="topbar-right">
              <ClusterPill health={health} />
              <Person me={me.data} />
              <button type="button" className="vault-link said-button" onClick={() => setDrawer(true)}>
                <ScrollText aria-hidden="true" />
                <span className="link-label">Vault said</span>
                <span className="said-count">
                  {log.length}
                  <span className="sr-only"> answers</span>
                </span>
              </button>
              <a className="vault-link" href={vaultUi} target="_blank" rel="noreferrer">
                <ExternalLink aria-hidden="true" />
                <span className="link-label">Vault UI</span>
                <span className="sr-only"> (opens in a new tab)</span>
              </a>
            </div>
          </header>
          <nav className="mobile-nav" aria-label="Rooms">
            <NavLinks route={route} className="mobile-nav__item" />
          </nav>
        </div>

        <main id="main" className="vg-content" tabIndex={-1}>
          {signinFailed && (
            <p className="inline-notice error" role="alert">
              Sign-in did not complete. Try again; if it keeps failing, run make identity-verify.
            </p>
          )}
          <page.Page key={page.id} />
        </main>
        <Footer />
      </div>

      <Drawer open={drawer} title="Vault said" onClose={() => setDrawer(false)}>
        <p className="drawer-intro">Every answer this page received, newest first, exactly as the API returned it. The API drops private keys before they reach the browser.</p>
        {log.length === 0 ? (
          <p className="dim">Nothing yet. Press a button in one of the rooms.</p>
        ) : (
          <ol className="said-list">
            {log.map((e) => (
              <li key={e.id} className="said-item">
                <div className="said-head">
                  <strong>{e.label}</strong>
                  <span className={`said-status ${e.status >= 200 && e.status < 300 ? 'ok' : 'bad'}`}>HTTP {e.status || '–'}</span>
                </div>
                <code className="said-path">
                  {e.method} {e.path}
                </code>
                <pre className="said-json">{JSON.stringify(e.body, null, 2)}</pre>
              </li>
            ))}
          </ol>
        )}
      </Drawer>
    </div>
    </AuthContext.Provider>
  );
}
