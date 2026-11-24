import { useEffect, useRef, useState, type FormEvent } from 'react';

type Mode = 'detecting' | 'basic' | 'session' | 'error';
type IdentityResponse = { authenticated?: boolean; roles?: string[] };
type ModeResponse = { mode?: string };

/** Opt-in HTTPS Identity login. No admin password or session token is persisted in the browser. */
export function SessionLogin() {
  const [mode, setMode] = useState<Mode>('detecting');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const csrfToken = useRef('');

  useEffect(() => {
    const controller = new AbortController();
    const reset = () => {
      setPassword('');
      setError('');
      setBusy(false);
      csrfToken.current = '';
      void getCsrf(controller.signal).catch(() => setError('تعذر تجديد رمز حماية الجلسة.'));
    };
    window.addEventListener('radius-session-logged-out', reset);
    async function discover() {
      try {
        const response = await fetch('/api/admin/auth/mode', {
          signal: controller.signal, credentials: 'same-origin', cache: 'no-store',
        });
        if (!response.ok) throw new Error('تعذر التحقق من نمط المصادقة.');
        const data = await response.json() as ModeResponse;
        if (controller.signal.aborted) return;
        if (data.mode === 'basic') {
          setMode('basic');
          return;
        }
        if (data.mode !== 'session' || window.location.protocol !== 'https:') {
          throw new Error('هذه الجلسة تتطلب اتصال HTTPS موثوقا.');
        }
        document.getElementById('loginForm')?.setAttribute('hidden', '');
        // Do not expose the login form before its initial CSRF request finishes.
        await getCsrf(controller.signal);
        if (controller.signal.aborted) return;
        setMode('session');
        const current = await fetch('/api/admin/auth/me', {
          signal: controller.signal, credentials: 'same-origin', cache: 'no-store',
        });
        if (current.ok && !controller.signal.aborted) {
          const me = await current.json() as IdentityResponse;
          if (me.authenticated) {
            await getCsrf(controller.signal);
            notifyHost();
          }
        }
      } catch {
        if (!controller.signal.aborted) {
          // Never fall back to Basic after a failed session-mode handshake.
          document.getElementById('loginForm')?.setAttribute('hidden', '');
          setMode('error');
          setError('تعذر بدء تسجيل الدخول الآمن. تحقق من اتصال HTTPS ثم أعد تحميل الصفحة.');
        }
      }
    }
    void discover();
    return () => {
      controller.abort();
      window.removeEventListener('radius-session-logged-out', reset);
    };
  }, []);

  async function getCsrf(signal?: AbortSignal) {
    const response = await fetch('/api/admin/auth/csrf', {
      signal, credentials: 'same-origin', cache: 'no-store',
    });
    if (!response.ok) throw new Error('تعذر توفير رمز CSRF.');
    const data = await response.json() as { requestToken?: string };
    if (!data.requestToken || typeof data.requestToken !== 'string') {
      throw new Error('تعذر التحقق من حماية الجلسة.');
    }
    csrfToken.current = data.requestToken;
  }

  function notifyHost() {
    // Notification only; the legacy dashboard still validates server-side
    // cookies and roles before rendering protected data.
    window.dispatchEvent(new CustomEvent('radius-session-ready', {
      detail: { csrf: csrfToken.current },
    }));
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (mode !== 'session' || !username.trim() || !password || busy) return;
    setBusy(true);
    setError('');
    try {
      await getCsrf();
      const response = await fetch('/api/admin/auth/login', {
        method: 'POST',
        credentials: 'same-origin',
        cache: 'no-store',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-TOKEN': csrfToken.current,
        },
        body: JSON.stringify({ username: username.trim(), password }),
      });
      if (!response.ok) {
        throw new Error(response.status === 401
          ? 'اسم المستخدم أو كلمة المرور غير صحيحين.'
          : response.status === 429
            ? 'محاولات كثيرة. حاول مرة أخرى لاحقا.'
            : 'تعذر تسجيل الدخول. تحقق من صلاحية الحساب والخادم.');
      }
      setPassword('');
      await getCsrf(); // Rebind anti-forgery token to authenticated principal.
      const current = await fetch('/api/admin/auth/me', {
        credentials: 'same-origin', cache: 'no-store',
      });
      if (!current.ok) throw new Error('تعذر التحقق من جلسة المسؤول بعد تسجيل الدخول.');
      const data = await current.json() as IdentityResponse;
      if (!data.authenticated) throw new Error('لم يتم اعتماد جلسة المسؤول.');
      notifyHost();
    } catch (err) {
      setPassword('');
      setError(err instanceof Error ? err.message : 'حدث خطأ في تسجيل الدخول.');
    } finally {
      setBusy(false);
    }
  }

  if (mode === 'basic') return null;
  if (mode === 'detecting') return <p role="status">جار تحديد وضع تسجيل الدخول الآمن...</p>;
  if (mode === 'error') return <p className="form-error" role="alert">{error}</p>;

  return (
    <form onSubmit={event => { void submit(event); }} aria-label="تسجيل دخول المسؤول الآمن">
      <label htmlFor="sessionLoginUser">اسم المستخدم</label>
      <input id="sessionLoginUser" name="username" autoComplete="username"
        value={username} required maxLength={80}
        onChange={event => setUsername(event.target.value)} />
      <label htmlFor="sessionLoginPass">كلمة المرور</label>
      <input id="sessionLoginPass" name="password" type="password"
        autoComplete="current-password" required value={password}
        onChange={event => setPassword(event.target.value)} />
      <button className="btn primary login-submit" type="submit" disabled={busy}>
        {busy ? 'جار التحقق...' : 'الدخول إلى اللوحة عبر HTTPS'}
      </button>
      {error && <p role="alert" className="form-error">{error}</p>}
    </form>
  );
}
