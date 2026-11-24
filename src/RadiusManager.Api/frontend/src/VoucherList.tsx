import { useEffect, useState } from 'react';

type Voucher = { username: string; planName: string; active: boolean };
type VoucherData = {
  loadedCount: number;
  visibleCount: number;
  visible: Voucher[];
  scope: 'first-100-loaded';
};
type Health = 'unloaded' | 'online' | 'error';
type ListState = { data: VoucherData | null; health: Health };

/** Read-only React presentation of already-authenticated, allowlisted lab cards. */
export function VoucherList() {
  const [state, setState] = useState<ListState>({ data: null, health: 'unloaded' });
  useEffect(() => {
    const update = (event: Event) => {
      const next = (event as CustomEvent<ListState>).detail;
      if (!next || !['unloaded', 'online', 'error'].includes(next.health)) return;
      if (next.health === 'unloaded') {
        setState({ data: null, health: 'unloaded' });
      } else {
        setState(previous => ({
          data: next.data?.scope === 'first-100-loaded' ? next.data : previous.data,
          health: next.health,
        }));
      }
    };
    window.addEventListener('radius-vouchers-updated', update);
    window.dispatchEvent(new Event('radius-vouchers-request'));
    return () => window.removeEventListener('radius-vouchers-updated', update);
  }, []);
  const rows = state.data?.visible ?? [];
  return (
    <>
      {state.health === 'error' &&
        <p role="status" className="section-note">تعذر تحديث الكروت؛ البيانات السابقة قد لا تعكس حالة الخادم الحالية.</p>}
      <table aria-label="كروت المختبر المحملة">
        <thead><tr><th>رقم الكرت</th><th>الباقة</th><th>الحالة</th><th>الإجراءات</th></tr></thead>
        <tbody>
          {rows.length === 0
            ? <tr><td colSpan={4}>{state.data
                ? state.data.loadedCount > 0 ? 'لا توجد كروت مطابقة للبحث.' : 'لا توجد كروت مختبر حتى الآن.'
                : 'لا توجد بيانات محملة'}</td></tr>
            : rows.map(card => <tr key={card.username}>
              <td>{card.username}</td>
              <td>{card.planName}</td>
              <td><span className={card.active ? 'pill good' : 'pill off'}>
                {card.active ? 'مفعّل' : 'موقوف'}
              </span></td>
              <td>
                <button type="button" className="btn subtle"
                  onClick={() => window.dispatchEvent(new CustomEvent('radius-voucher-usage', {
                    detail: { username: card.username },
                  }))}>الاستهلاك</button>
                {card.active &&
                  <button type="button" className="btn danger"
                    onClick={() => window.dispatchEvent(new CustomEvent('radius-voucher-disable', {
                      detail: { username: card.username },
                    }))}>تعطيل</button>}
              </td>
            </tr>)}
        </tbody>
      </table>
      <p role="status" className="table-caption">
        {state.data
          ? `المعروض ${state.data.visibleCount} من ${state.data.loadedCount} كرت محمل (حد القراءة: 100)`
          : 'سيتوفر العدد بعد قراءة البيانات.'}
      </p>
    </>
  );
}
