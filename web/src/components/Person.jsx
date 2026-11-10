// components/Person.jsx: who is signed in (D16), from vault_codex. Sign-in is
// Keycloak's own page (federated from OpenLDAP); the API keeps the tokens.
import { useState } from 'react';
import { LogIn, LogOut, UserRound } from 'lucide-react';

const ROLE = { admin: 'Admin: runs the drill', operator: 'Operator: runs the drill', viewer: 'Viewer: watches' };
export const signInHref = () => `/auth/login?return=${encodeURIComponent(`/${window.location.hash.split('?')[0] || '#/room'}`)}`;

export default function Person({ me }) {
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
          <div className="umf-row umf-meta">{ROLE[me.role] ?? 'No drill role in the directory'}</div>
          <div className="umf-row umf-meta">Signed in through Keycloak; the directory decides the role.</div>
          <a className="umf-signout" href="/auth/logout">
            <LogOut size={12} aria-hidden="true" /> Sign out
          </a>
        </div>
      )}
    </div>
  );
}
