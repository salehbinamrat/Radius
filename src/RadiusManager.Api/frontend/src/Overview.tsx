import { useEffect, useState } from 'react';

type Card = { username: string; planName: string; active: boolean };
type Snapshot = {
  plans: number | null;
  labAccounts: number | null;
  activeInLoadedAccounts: number;
  loadedAccountCount: number;
  recent: Card[];
  scope: 'first-100-loaded';
};
type OverviewEvent = { snapshot?: Snapshot | null; health?: 'unloaded' | 'online' | 'error' };
type State = { snapshot: Snapshot | null; health: 'unloaded' | 'online' | 'error' };

function useOverview() {
  const [state, setState] = useState<State>({ snapshot: null, health: 'unloaded' });
  useEffect(() => {
    const update = (event: Event) => {
      const { detail } = event as CustomEvent<OverviewEvent>;
      if (!detail || !['unloaded', 'online', 'error'].includes(detail.health ?? '')) return;
      if (detail.health === 'unloaded') {
        setState({ snapshot: null, health: 'unloaded' });
        return;
      }
      setState(previous => ({
        snapshot: detail.snapshot?.scope === 'first-100-loaded'
          ? detail.snapshot : previous.snapshot,
        health: detail.health ?? previous.health,
      }));
    };
    window.addEventListener('radius-overview-updated', update);
    window.dispatchEvent(new Event('radius-overview-request'));
    return () => window.removeEventListener('radius-overview-updated', update);
  }, []);
  return state;
}

function displayCount(count: number | null | undefined): string {
  return typeof count === 'number' && Number.isSafeInteger(count) && count >= 0
    ? count.toLocaleString('en-US') : '—';
}

function Kpi({ icon, accent, title, value, note, className = '' }: {
  icon: string; accent: string; title: string; value: string; note: string; className?: string;
}) {
  return (
    <article className="kpi-card">
      <span className={'kpi-icon ' + accent}>
        <svg className="ico" aria-hidden="true"><use href={'#' + icon} /></svg>
      </span>
      <span className="kpi-label">{title}</span>
      <strong className={className}>{value}</strong>
      <small>{note}</small>
    </article>
  );
}

/** Authenticated server statistics, never hard-coded router availability. */
export function OverviewKpis() {
  const { snapshot, health } = useOverview();
  const old = health === 'error' ? 'البيانات السابقة — التحديث تعذر' : 'من قاعدة البيانات';
  return (
    <>
      <Kpi icon="i-layers" accent="blue" title="الباقات المسجلة"
        value={displayCount(snapshot?.plans)} note={old} />
      <Kpi icon="i-ticket" accent="purple" title="حسابات المختبر"
        value={displayCount(snapshot?.labAccounts)}
        note={health === 'error' ? old : 'الإجمالي من الخادم'} />
      <Kpi icon="i-check" accent="teal" title="كروت مفعلة في القائمة"
        value={displayCount(snapshot?.activeInLoadedAccounts)}
        note={health === 'error' ? old : 'من أول 100 كرت معروض فقط'} />
      <Kpi icon="i-shield" accent="amber" title="سلامة الاتصال بالواجهة"
        value={health === 'online' ? 'متصل' : health === 'error' ? 'خطأ' : '—'}
        className={'health-metric ' + (health === 'online' ? 'good' : health === 'error' ? 'bad' : '')}
        note="نتيجة آخر طلب بيانات للإدارة؛ لا تعني اتصال الراوتر" />
    </>
  );
}

/** Exactly five most recent loaded test cards; React escapes user-provided text. */
export function OverviewRecent() {
  const { snapshot, health } = useOverview();
  const rows = snapshot?.recent ?? [];
  return (
    <>
      {health === 'error' &&
        <p role="status" className="section-note">تعذر تحديث البيانات؛ المعروض هو البيانات السابقة إن وجدت.</p>}
      <table aria-label="آخر كروت المختبر المحملة">
        <thead><tr><th>الكرت</th><th>الباقة</th><th>الحالة</th></tr></thead>
        <tbody>
          {rows.length === 0
            ? <tr><td colSpan={3}>{snapshot
                ? 'لا توجد كروت اختبار مسجلة حتى الآن.'
                : 'البيانات لم تُحمّل بعد'}</td></tr>
            : rows.map((card, i) => (
              <tr key={card.username + '-' + i}>
                <td>{card.username}</td><td>{card.planName}</td>
                <td><span className={card.active ? 'pill good' : 'pill off'}>
                  {card.active ? 'مفعّل' : 'موقوف'}
                </span></td>
              </tr>
            ))}
        </tbody>
      </table>
      <p className="section-note">هذه النتائج من أول 100 كرت مسترجع فقط، وليست كل حسابات الشبكة.</p>
    </>
  );
}
