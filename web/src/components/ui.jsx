// components/ui.jsx: small shared pieces (vault_codex). Colour only for
// state: ok, warn, denied, info, and the role pills (approved, healthy,
// manual, pending, rejected).
import { useEffect, useRef } from 'react';
import { CircleCheck, CircleX, TriangleAlert, X } from 'lucide-react';

const PILL = { ok: 'healthy', warn: 'pending', denied: 'rejected', info: 'approved' };

export function StatePill({ state, children }) {
  const kind = PILL[state] ?? state ?? 'manual';
  const Icon = state === 'ok' ? CircleCheck : state === 'denied' ? CircleX : state === 'warn' ? TriangleAlert : null;
  return (
    <span className={`vg-pill vg-pill--${kind}`}>
      {Icon && <Icon size={12} aria-hidden="true" />}
      {children}
    </span>
  );
}

export function Mono({ children, title }) {
  return (
    <code className="mono" title={title}>
      {children}
    </code>
  );
}

export function ErrorNotice({ error, title }) {
  if (!error) return null;
  return (
    <div className="inline-notice error" role="alert">
      <strong>{title || 'The API did not answer'}</strong>
      {error.status ? <span className="vault-status"> HTTP {error.status}</span> : null}
      <p className="m-0">{error.body?.error?.message ?? error.message}</p>
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

export function Loading({ label = 'Asking Vault…' }) {
  return (
    <div className="vg-loading" role="status">
      <span className="vg-live-dot" aria-hidden="true" />
      {label}
    </div>
  );
}

// The page's one ink pane.
export function Hero({ kicker, title, children, id = 'hero-h' }) {
  return (
    <section className="vg-hero room-hero" aria-labelledby={id}>
      {kicker && <p className="room-hero__kicker">{kicker}</p>}
      <h2 id={id} className="hero-title room-hero__title">
        {title}
      </h2>
      {children}
    </section>
  );
}

// "4 s ago", for a value that is older than it should be.
export const ago = (iso, now = Date.now()) => {
  if (!iso) return 'never';
  const s = Math.max(0, Math.round((now - Date.parse(iso)) / 1000));
  return s < 90 ? `${s} s ago` : s < 5400 ? `${Math.round(s / 60)} min ago` : `${Math.round(s / 3600)} h ago`;
};
export const hms = (iso) => (iso ? new Date(iso).toISOString().slice(11, 19) : '-');
