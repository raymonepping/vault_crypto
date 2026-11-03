// components/ui.jsx — small shared pieces. Colour only for state (DESIGN.md):
// family (classic / post-quantum), ok, warn, denied.
import { createContext, useContext, useEffect, useRef } from 'react';
import { CircleCheck, CircleX, TriangleAlert, X, Lock, LogIn } from 'lucide-react';

// The signed-in person and what Vault allows them (GET /api/me).
export const AuthContext = createContext({ signedIn: false });
export const useAuth = () => useContext(AuthContext);
export const signInHref = () => `/auth/login?return=${encodeURIComponent(`/${window.location.hash.split('?')[0] || '#/overview'}`)}`;

// Vault's errors arrive as "1 error occurred:\n\t* permission denied\n\n".
const tidy = (v) => String(v).replace(/^\d+ errors? occurred:\s*/, '').replace(/^\*\s*/, '').replace(/\s+/g, ' ').trim();

export function FamilyPill({ family, children }) {
  const cls = { 'post-quantum': 'fam fam--pq', classic: 'fam fam--classic', symmetric: 'fam fam--sym' }[family] || 'fam fam--unknown';
  return <span className={cls}>{children || family || 'unknown'}</span>;
}

export function StatePill({ state, children }) {
  const map = { ok: 'vg-pill vg-pill--healthy', warn: 'vg-pill vg-pill--pending', denied: 'vg-pill vg-pill--rejected', info: 'vg-pill vg-pill--approved' };
  const Icon = state === 'ok' ? CircleCheck : state === 'denied' ? CircleX : state === 'warn' ? TriangleAlert : null;
  return (
    <span className={map[state] || 'vg-pill vg-pill--manual'}>
      {Icon && <Icon size={12} aria-hidden="true" />}
      {children}
    </span>
  );
}

// An error from the API, with Vault's own error lines verbatim.
export function ErrorNotice({ error, title }) {
  if (!error) return null;
  if (error.status === 401) return <SignInNotice />;
  const vault = (error.body?.vault || []).map(tidy);
  return (
    <div className="inline-notice error" role="alert">
      <strong>{title || 'Refused'}</strong>
      {error.status ? <span className="vault-status"> HTTP {error.status}</span> : null}
      {vault.length ? (
        <ul className="vault-errors">
          {vault.map((v) => (
            <li key={v}>
              Vault said: <code>{v}</code>
            </li>
          ))}
        </ul>
      ) : (
        <p className="m-0">{error.message}</p>
      )}
    </div>
  );
}

export function SignInNotice() {
  return (
    <div className="vg-card signin-notice" role="status">
      <p>
        <strong>Sign in to use this room.</strong> Every action here runs on a Vault token issued to you, and Vault decides what you may do.
      </p>
      <a className="primary-button" href={signInHref()}>
        <LogIn size={14} aria-hidden="true" /> Sign in
      </a>
    </div>
  );
}

// A lock on an action Vault will refuse this person. The button stays
// clickable: the refusal is Vault's, not the console's.
export function Locked({ action }) {
  const me = useAuth();
  const a = me.actions?.[action];
  if (!me.signedIn || !a || a.allowed) return null;
  return (
    <span className="locked" title={`Vault will refuse: needs ${a.group}`}>
      <Lock size={12} aria-hidden="true" />
      <span className="sr-only"> (Vault will refuse: needs {a.group})</span>
    </span>
  );
}

// What the signed-in person may do in a room, as Vault answered.
export function Authority({ actions }) {
  const me = useAuth();
  if (!me.signedIn) return null;
  return (
    <section className="authority" aria-label="Your authority in this room">
      <span className="authority__who">
        {me.name} <span className="dim">via {me.policies?.join(', ') || 'no policy'}</span>
      </span>
      <ul className="authority__list">
        {actions.map(([id, label]) => {
          const a = me.actions?.[id];
          return (
            <li key={id}>
              {a?.allowed ? (
                <StatePill state="ok">{label}</StatePill>
              ) : (
                <span className="vg-pill vg-pill--rejected" title={a ? `needs ${a.group}` : ''}>
                  <Lock size={11} aria-hidden="true" /> {label}
                </span>
              )}
            </li>
          );
        })}
      </ul>
    </section>
  );
}

export function Mono({ children, title }) {
  return (
    <code className="mono" title={title}>
      {children}
    </code>
  );
}

// Horizontal byte bars, drawn in SVG so the strict CSP needs no inline styles.
export function ByteBars({ rows, max }) {
  const top = max || Math.max(1, ...rows.flatMap((r) => r.values.map((v) => v.value || 0)));
  return (
    <div className="bars" role="table" aria-label="Size comparison in bytes">
      {rows.map((r) => (
        <div className="bars__row" role="row" key={r.label}>
          <span className="bars__label" role="rowheader">
            {r.label}
          </span>
          <div className="bars__set" role="cell">
            {r.values.map((v) => (
              <div className="bars__bar" key={v.key}>
                <svg viewBox="0 0 100 10" preserveAspectRatio="none" aria-hidden="true" focusable="false">
                  <rect className="bars__track" x="0" y="0" width="100" height="10" rx="2" />
                  <rect className={`bars__fill bars__fill--${v.family === 'post-quantum' ? 'pq' : 'classic'}`} x="0" y="0" width={Math.max(0.8, (100 * (v.value || 0)) / top)} height="10" rx="2" />
                </svg>
                <span className="bars__value">
                  <FamilyPill family={v.family}>{v.key}</FamilyPill> {v.value == null ? '–' : `${v.value.toLocaleString('en-GB')} B`}
                </span>
              </div>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

// Right-hand drawer; Escape and the backdrop close it; focus moves in.
export function Drawer({ open, title, onClose, children }) {
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const prev = document.activeElement;
    ref.current?.focus();
    const onKey = (e) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('keydown', onKey);
      prev?.focus?.();
    };
  }, [open, onClose]);
  if (!open) return null;
  return (
    <>
      <div className="vg-drawer-backdrop" onClick={onClose} aria-hidden="true" />
      <aside className="vg-drawer" role="dialog" aria-modal="true" aria-label={title} tabIndex={-1} ref={ref}>
        <div className="vg-drawer__header">
          <h2 className="vg-drawer__title">{title}</h2>
          <button type="button" className="vg-btn vg-btn--ghost" onClick={onClose} aria-label="Close">
            <X size={16} aria-hidden="true" />
          </button>
        </div>
        <div className="vg-drawer__body">{children}</div>
      </aside>
    </>
  );
}

// Confirmation with the native <dialog> (focus trap and Escape for free).
export function Confirm({ open, title, children, confirmLabel, onConfirm, onCancel, busy }) {
  const ref = useRef(null);
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);
  return (
    <dialog ref={ref} className="confirm vg-glass" onClose={onCancel} aria-labelledby="confirm-title">
      <h2 id="confirm-title">{title}</h2>
      <div className="confirm__body">{children}</div>
      <div className="form-actions">
        <button type="button" className="secondary-button" onClick={onCancel}>
          Cancel
        </button>
        <button type="button" className="destructive-button" onClick={onConfirm} disabled={busy}>
          {busy ? 'Working…' : confirmLabel}
        </button>
      </div>
    </dialog>
  );
}

export function Loading({ label = 'Asking Vault…' }) {
  return (
    <div className="vg-loading" role="status">
      <span className="vg-live-dot" aria-hidden="true" />
      {label}
    </div>
  );
}

export function Check({ ok, yes, no }) {
  return ok ? <StatePill state="ok">{yes}</StatePill> : <StatePill state="denied">{no}</StatePill>;
}
