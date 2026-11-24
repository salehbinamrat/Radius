import { useEffect, useState } from 'react';

type SessionRow = {
  username: string;
  framedIp: string;
  callingStationId: string;
  nasIp: string;
  status: string;
  classification: 'closed' | 'stale' | 'open-unconfirmed' | 'anomaly' | 'unknown';
  startedAt: string;
  updatedAt: string;
  transfer: string;
  terminateCause: string;
};
type SessionSnapshot = {
  loadedCount: number;
  visibleCount: number;
  visible: SessionRow[];
  scope: 'first-100-loaded';
};
type Health = 'unloaded' | 'online' | 'error';
type ViewState = { snapshot: SessionSnapshot | null; health: Health };

/** Renders classified accounting rows only; never claims a currently connected NAS. */
export function SessionTable() {
  const [state, setState] = useState<ViewState>({ snapshot: null, health: 'unloaded' });
  useEffect(() => {
    const update = (event: Event) => {
      const next = (event as CustomEvent<ViewState>).detail;
      if (!next || !['unloaded', 'online', 'error'].includes(next.health)) return;
      if (next.health === 'unloaded') {
        setState({ snapshot: null, health: 'unloaded' });
      } else {
        setState(previous => ({
          snapshot: next.snapshot?.scope === 'first-100-loaded'
            ? next.snapshot : previous.snapshot,
          health: next.health,
        }));
      }
    };
    window.addEventListener('radius-sessions-updated', update);
    window.dispatchEvent(new Event('radius-sessions-request'));
    return () => window.removeEventListener('radius-sessions-updated', update);
  }, []);

  const rows = state.snapshot?.visible ?? [];
  return (
    <>
      <table className="ultra-table" aria-label="سجلات المحاسبة التجريبية للقراءة فقط">
        <thead><tr>
          <th>الكرت</th><th>IP</th><th>MAC</th><th>NAS</th>
          <th>حالة السجل</th><th>بداية الجلسة</th><th>آخر تحديث</th>
          <th>رفع / تنزيل</th><th>سبب الإنهاء</th>
        </tr></thead>
        <tbody>
          {rows.length === 0 ? <tr><td colSpan={9}>
            {state.health === 'error' ? 'تعذر تحميل سجلات المحاسبة.'
              : state.health === 'unloaded' ? 'اختر «قراءة من الخادم» لعرض البيانات.'
                : 'لا توجد سجلات مطابقة في النتائج المحملة.'}
          </td></tr> : rows.map((row, index) => (
            <tr key={row.username + ':' + index} data-state={row.classification}>
              <td>{row.username}</td>
              <td>{row.framedIp}</td><td>{row.callingStationId}</td><td>{row.nasIp}</td>
              <td>{row.status}</td>
              <td>{row.startedAt}</td><td>{row.updatedAt}</td>
              <td>{row.transfer}</td><td>{row.terminateCause}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="ultra-note" role="status">
        {state.snapshot
          ? 'المعروض ' + state.snapshot.visibleCount + ' من ' +
            state.snapshot.loadedCount + ' سجل محمل. مفتوحة (غير مؤكدة) لا تعني اتصالا حيا.'
          : 'السجلات لم تُحمّل بعد، وليست إحصاء للمتصلين حاليا.'}
      </p>
    </>
  );
}
