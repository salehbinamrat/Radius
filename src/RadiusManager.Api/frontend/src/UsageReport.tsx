import { useEffect, useState } from 'react';

type UsageSnapshot = {
  username: string;
  total: string;
  download: string;
  upload: string;
  sessions: string;
  openSessions: string;
  staleSessions: string;
  anomalousSessions: string;
  observedNas: string;
  finality: string;
  warning: string;
  scope: 'lab-accounting-estimate';
};
type UsageState =
  | { kind: 'unloaded' }
  | { kind: 'loading' }
  | { kind: 'error'; error: string }
  | { kind: 'success'; snapshot: UsageSnapshot };
const empty: UsageState = { kind: 'unloaded' };

function Metric({ title, value }: { title: string; value: string }) {
  return <div><span>{title}</span><strong>{value}</strong></div>;
}

/** Visual-only React 19 report. Authenticated API, CSRF and request ordering
 * remain owned by the NOC controller (app.mjs). Never display a final balance.
 */
export function UsageReport() {
  const [state, setState] = useState<UsageState>(empty);

  useEffect(() => {
    const update = (event: Event) => {
      const next = (event as CustomEvent<Partial<UsageState>>).detail;
      if (!next || typeof next.kind !== 'string') return;
      switch (next.kind) {
        case 'unloaded':
          setState({ kind: 'unloaded' });
          break;
        case 'loading':
          setState({ kind: 'loading' });
          break;
        case 'error':
          setState({ kind: 'error', error: typeof next.error === 'string'
            ? next.error : 'تعذر قراءة الاستهلاك.' });
          break;
        case 'success':
          if ('snapshot' in next && next.snapshot?.scope === 'lab-accounting-estimate') {
            setState({ kind: 'success', snapshot: next.snapshot });
          }
          break;
      }
    };
    window.addEventListener('radius-usage-updated', update);
    window.dispatchEvent(new Event('radius-usage-request'));
    return () => window.removeEventListener('radius-usage-updated', update);
  }, []);

  if (state.kind !== 'success') {
    const title = state.kind === 'loading'
      ? 'جار قراءة الاستهلاك'
      : state.kind === 'error' ? 'تعذر قراءة الاستهلاك' : 'اختر كرتا لعرض البيانات';
    const description = state.kind === 'error' ? state.error
      : state.kind === 'loading'
        ? 'جار قراءة سجلات المحاسبة من الخادم.'
        : 'سيظهر إجمالي الرفع والتنزيل وحالة سجلات الجلسات هنا.';
    return <div className="empty-illustration" role="status" aria-live="polite">
      <svg className="ico" aria-hidden="true"><use href="#i-chart" /></svg>
      <strong>{title}</strong><span>{description}</span>
    </div>;
  }

  const report = state.snapshot;
  return <div aria-label={'تقرير استهلاك كرت المختبر ' + report.username}>
    <div className="usage-kpis">
      <Metric title="إجمالي البيانات" value={report.total} />
      <Metric title="التنزيل" value={report.download} />
      <Metric title="الرفع" value={report.upload} />
    </div>
    <div className="usage-details">
      <Metric title="إجمالي الجلسات" value={report.sessions} />
      <Metric title="المفتوحة" value={report.openSessions} />
      <Metric title="القديمة" value={report.staleSessions} />
      <Metric title="سجلات غير سليمة" value={report.anomalousSessions} />
      <Metric title="عناوين NAS المرصودة" value={report.observedNas} />
      <Metric title="حالة السجل" value={report.finality} />
    </div>
    <p role="note" className="warning-note">{report.warning}</p>
    <p className="section-note">الأرقام استرشادية من radacct وليست رصيدا نهائيا أو دليلا على الاتصال الحي.</p>
  </div>;
}
