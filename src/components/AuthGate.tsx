import { useEffect, useId, useState, type ReactNode } from 'react';
import { getSession, onAuthStateChange, signIn, signOut } from '../lib/auth';
import type { AppSession } from '../lib/auth';

/**
 * Auth gate (AC-005 / AC-007 / accessibility).
 *
 * Consumes the `auth.ts` seam ONLY — it never calls `supabase.auth` directly.
 * Renders a bare email/password login when signed out and `children` (the app)
 * when authed. Accessibility (WCAG 2.2 AA, scoped to this chrome): each input has
 * an associated <label>, correct input `type` + `autocomplete`, a real <button>
 * submit, and auth errors announced via `role="alert"` (not color alone). Fully
 * keyboard-operable with the browser's native focus order.
 */
export function AuthGate({
  children,
  headerSlot,
}: {
  children: ReactNode;
  /**
   * Optional controls rendered inside `.app-header` between the signed-in label
   * and the Sign out button — used by App to mount the Map ⇄ Sites view toggle
   * (App owns the `view` state; the header lives here, so the toggle is passed
   * down as a slot). Only rendered when signed in (the header only exists then).
   */
  headerSlot?: ReactNode;
}) {
  const [session, setSession] = useState<AppSession | null>(null);
  const [ready, setReady] = useState(false);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const emailId = useId();
  const passwordId = useId();

  useEffect(() => {
    let active = true;
    void getSession().then((s) => {
      if (active) {
        setSession(s);
        setReady(true);
      }
    });
    const subscription = onAuthStateChange((s) => {
      setSession(s);
      setReady(true);
    });
    return () => {
      active = false;
      subscription.unsubscribe();
    };
  }, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    const { error: signInError } = await signIn(email, password);
    if (signInError) {
      setError(signInError);
    }
    setSubmitting(false);
  }

  if (!ready) {
    return <p>Loading…</p>;
  }

  if (session) {
    return (
      <>
        <header className="app-header">
          <span>Signed in as {session.user.email}</span>
          {headerSlot}
          <button type="button" onClick={() => void signOut()}>
            Sign out
          </button>
        </header>
        {children}
      </>
    );
  }

  return (
    <main className="auth-gate">
      <h1>Sign in</h1>
      <form onSubmit={handleSubmit} noValidate>
        <div className="field">
          <label htmlFor={emailId}>Email</label>
          <input
            id={emailId}
            type="email"
            autoComplete="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </div>
        <div className="field">
          <label htmlFor={passwordId}>Password</label>
          <input
            id={passwordId}
            type="password"
            autoComplete="current-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        {error && (
          <p role="alert" aria-live="assertive" className="form-error">
            {error}
          </p>
        )}
        <button type="submit" disabled={submitting}>
          {submitting ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </main>
  );
}
