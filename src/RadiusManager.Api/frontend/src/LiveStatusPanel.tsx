import { useEffect, useState } from 'react';
import { HubConnectionBuilder, HttpTransportType, LogLevel, type ISubscription } from '@microsoft/signalr';
import { parseLabStatus, nextRetryDelay, LIVE_STALE_MS, type LabStatus } from '../../wwwroot/live-status-model.mjs';

type Status = 'connecting' | 'live' | 'stale' | 'unavailable';
type View = { status: Status; sample: LabStatus | null };
const initial: View = { status: 'connecting', sample: null };

/** Authenticated read-only status, not a router, FreeRADIUS or subscriber monitor. */
export function LiveStatusPanel() {
  const [enabled, setEnabled] = useState(false);
  const [view, setView] = useState<View>(initial);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const scope = (event: Event) => {
      const next = (event as CustomEvent<{ enabled?: boolean }>).detail?.enabled === true
        && window.location.protocol === 'https:';
      setEnabled(next);
      if (!next) setView(initial);
    };
    const logout = () => { setEnabled(false); setView(initial); };
    window.addEventListener('radius-live-status-scope', scope);
    window.addEventListener('radius-session-logged-out', logout);
    window.dispatchEvent(new Event('radius-live-status-request'));
    return () => {
      window.removeEventListener('radius-live-status-scope', scope);
      window.removeEventListener('radius-session-logged-out', logout);
    };
  }, []);

  useEffect(() => {
    if (!enabled) return;
    let disposed = false;
    let failures = 0;
    let generation = 0;
    let subscription: ISubscription<unknown> | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let staleTimer: ReturnType<typeof setTimeout> | undefined;
    let connection = createConnection();

    function createConnection() {
      return new HubConnectionBuilder()
        .withUrl('/hubs/lab-status', {
          transport: HttpTransportType.WebSockets, skipNegotiation: true,
        })
        .configureLogging(LogLevel.None)
        .build();
    }

    function clearTimers() {
      if (timer !== undefined) clearTimeout(timer);
      if (staleTimer !== undefined) clearTimeout(staleTimer);
      timer = undefined;
      staleTimer = undefined;
    }

    function stopAndRetry(current: number) {
      if (disposed || current !== generation) return;
      ++generation;
      clearTimers();
      subscription?.dispose();
      subscription = undefined;
      const oldConnection = connection;
      const delay = nextRetryDelay(failures++);
      setView(previous => ({
        status: delay === null ? 'unavailable' : 'stale',
        sample: previous.sample,
      }));
      void oldConnection.stop().catch(() => {}).then(() => {
        if (disposed || delay === null) return;
        timer = setTimeout(() => {
          if (!disposed) {
            connection = createConnection();
            void start();
          }
        }, delay);
      });
    }

    function armStaleTimer(current: number) {
      if (staleTimer !== undefined) clearTimeout(staleTimer);
      staleTimer = setTimeout(() => stopAndRetry(current), LIVE_STALE_MS);
    }

    function watch(current: number) {
      if (disposed || current !== generation) return;
      armStaleTimer(current);
      subscription = connection.stream<unknown>('Watch').subscribe({
        next: value => {
          if (disposed || current !== generation) return;
          const sample = parseLabStatus(value);
          if (!sample) { stopAndRetry(current); return; }
          failures = 0;
          setView({ status: 'live', sample });
          armStaleTimer(current);
        },
        error: () => stopAndRetry(current),
        complete: () => {
          if (disposed || current !== generation) return;
          subscription = undefined;
          // The server intentionally ends each stream after six samples.
          // Renew only the read subscription; never replay an old result.
          timer = setTimeout(() => watch(current), 1000);
        },
      });
    }

    async function start() {
      const current = ++generation;
      const activeConnection = connection;
      activeConnection.onclose(() => stopAndRetry(current));
      armStaleTimer(current);
      try {
        await activeConnection.start();
        if (disposed || current !== generation) {
          await activeConnection.stop();
          return;
        }
        watch(current);
      } catch {
        stopAndRetry(current);
      }
    }

    setView(initial);
    void start();
    return () => {
      disposed = true;
      ++generation;
      clearTimers();
      subscription?.dispose();
      void connection.stop().catch(() => {});
    };
  }, [enabled, attempt]);

  if (!enabled) return null;
  const text = view.status === 'live' ? 'بث قاعدة البيانات متصل'
    : view.status === 'connecting' ? 'جار الاتصال بالبث اللحظي'
    : view.status === 'stale' ? 'البث منقطع — جار إعادة المحاولة'
    : 'البث غير متاح';
  return (
    <div className="noc-service-row" data-live-status={view.status}>
      <div>
        <span role="status" aria-live="polite">
          <i className={'noc-led ' + (view.status === 'live' ? 'good' : 'unknown')} />
          {' ' + text}
        </span>
        <p className="section-note">
          {view.sample ? (view.status === 'live' ? 'آخر تحقق: ' : 'بيانات سابقة غير مؤكدة: ')
            + new Date(view.sample.observedAtUtc).toLocaleString('ar')
            : 'لم يتم استلام تحقق لحظي من الخادم بعد.'}
        </p>
        <p className="section-note">
          ASP.NET Core: {view.status === 'live' && view.sample ? 'يعمل' : 'غير مؤكد'}
          {' — PostgreSQL: '}{view.status === 'live' && view.sample ? 'يمكن الوصول إليه' : 'غير مؤكد'}
        </p>
        <p className="section-note" data-session-check-ms={view.status === 'live' ? view.sample?.sessionCheckMs : undefined}>
          زمن التحقق من الجلسة: {view.status === 'live' && view.sample
            ? view.sample.sessionCheckMs.toLocaleString('en-US', { maximumFractionDigits: 2 }) + ' ms'
            : '—'}
        </p>
        <p className="section-note">قياس مسار القراءة والتحقق فقط، وليس زمن الشبكة أو حالة الراوترات أو FreeRADIUS.</p>
      </div>
      {view.status === 'unavailable' &&
        <button type="button" className="btn" onClick={() => setAttempt(value => value + 1)}>إعادة الاتصال</button>}
    </div>
  );
}
