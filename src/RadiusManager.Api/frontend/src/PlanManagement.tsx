import { useEffect, useState, type FormEvent } from 'react';

type Plan = {
  id: string;
  name: string;
  downloadKbps: number;
  uploadKbps: number;
  quotaBytes: number | null;
  validityDays: number | null;
  active: boolean;
  downloadText: string;
  uploadText: string;
};
type Display = {
  visible: Plan[];
  visibleCount: number;
  loadedCount: number;
  scope: 'first-100-loaded';
};
type Health = 'unloaded' | 'online' | 'error';
type ListState = { data: Display | null; health: Health };
type FormFields = { name: string; down: string; up: string; quota: string; days: string };
type SaveReply = { ok: boolean; error?: string };
const initial = (): FormFields => ({ name: '', down: '1024', up: '256', quota: '', days: '' });

/** React owns plan inputs, but the existing authenticated app owns API/CSRF and validation. */
export function PlanEditor() {
  const [fields, setFields] = useState<FormFields>(initial);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    const clear = () => {
      setFields(initial()); setEditingId(null); setError('');
    };
    const edit = (event: Event) => {
      const plan = (event as CustomEvent<Plan>).detail;
      if (!plan || typeof plan.id !== 'string' || typeof plan.name !== 'string') return;
      setEditingId(plan.id);
      setFields({
        name: plan.name,
        down: String(plan.downloadKbps),
        up: String(plan.uploadKbps),
        quota: plan.quotaBytes === null ? '' : String(Math.floor(plan.quotaBytes / 1048576)),
        days: plan.validityDays === null ? '' : String(plan.validityDays),
      });
      setError('');
      requestAnimationFrame(() => document.getElementById('planName')?.focus());
    };
    window.addEventListener('radius-plan-clear-edit', clear);
    window.addEventListener('radius-plan-edit', edit);
    return () => {
      window.removeEventListener('radius-plan-clear-edit', clear);
      window.removeEventListener('radius-plan-edit', edit);
    };
  }, []);

  function update<K extends keyof FormFields>(key: K, value: FormFields[K]) {
    setFields(previous => ({ ...previous, [key]: value }));
  }
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    setError('');
    try {
      const answer = await new Promise<SaveReply>(resolve => {
        window.dispatchEvent(new CustomEvent('radius-plan-save-request', {
          detail: { id: editingId, fields: { ...fields }, respond: resolve },
        }));
      });
      if (!answer.ok) throw new Error(answer.error || 'تعذر حفظ الباقة.');
      setFields(initial());
      setEditingId(null);
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'تعذر حفظ الباقة.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <form id="planForm" className="form-stack" onSubmit={event => { void save(event); }}>
        <label htmlFor="planName">اسم الباقة <span>*</span></label>
        <input id="planName" maxLength={80} required placeholder="مثال: باقة 1M"
          value={fields.name} onChange={event => update('name', event.target.value)} />
        <div className="field-pair">
          <div>
            <label htmlFor="planDown">التنزيل (Kbps) <span>*</span></label>
            <input id="planDown" type="number" inputMode="numeric" required
              min={64} max={1000000} value={fields.down}
              onChange={event => update('down', event.target.value)} />
          </div>
          <div>
            <label htmlFor="planUp">الرفع (Kbps) <span>*</span></label>
            <input id="planUp" type="number" inputMode="numeric" required
              min={64} max={1000000} value={fields.up}
              onChange={event => update('up', event.target.value)} />
          </div>
        </div>
        <div className="info-hint">
          <svg className="ico" aria-hidden="true"><use href="#i-info" /></svg>
          ترتيب السرعات في RADIUS: الرفع / التنزيل، وسيجري تحويل القيم تلقائيا.
        </div>
        <div className="field-pair">
          <div>
            <label htmlFor="planQuota">الحجم (MB) <span className="optional">غير مفعل</span></label>
            <input id="planQuota" type="number" inputMode="numeric" min={1}
              placeholder="بدون حد" value={fields.quota}
              onChange={event => update('quota', event.target.value)} />
          </div>
          <div>
            <label htmlFor="planDays">المدة (يوم) <span className="optional">غير مفعلة</span></label>
            <input id="planDays" type="number" inputMode="numeric" min={1} max={3650}
              placeholder="بدون حد" value={fields.days}
              onChange={event => update('days', event.target.value)} />
          </div>
        </div>
        <div className="form-actions">
          <button id="savePlan" className="btn primary" type="submit" disabled={busy}>
            {busy ? 'جار الحفظ...' : editingId ? 'حفظ التعديل' : 'حفظ الباقة'}
          </button>
          {editingId && <button id="cancelEdit" className="btn subtle" type="button"
            disabled={busy} onClick={() => window.dispatchEvent(new Event('radius-plan-clear-edit'))}>
            إلغاء التعديل
          </button>}
        </div>
        <p id="planError" className="form-error" role="alert" aria-live="polite">{error}</p>
      </form>
    </>
  );
}

/** Read-only plan rows; row actions signal the editor, never bypass server authorization. */
export function PlansTable() {
  const [state, setState] = useState<ListState>({ data: null, health: 'unloaded' });
  useEffect(() => {
    const update = (event: Event) => {
      const payload = (event as CustomEvent<ListState>).detail;
      if (!payload || !['unloaded', 'online', 'error'].includes(payload.health)) return;
      if (payload.health === 'unloaded') {
        setState({ data: null, health: 'unloaded' });
      } else {
        setState(previous => ({
          data: payload.data?.scope === 'first-100-loaded' ? payload.data : previous.data,
          health: payload.health,
        }));
      }
    };
    window.addEventListener('radius-plans-updated', update);
    window.dispatchEvent(new Event('radius-plans-request'));
    return () => window.removeEventListener('radius-plans-updated', update);
  }, []);
  const rows = state.data?.visible ?? [];
  return (
    <>
      {state.health === 'error' && <p role="status" className="section-note">
        تعذر تحديث القائمة؛ البيانات السابقة لا تعكس حالة الخادم الحالية.
      </p>}
      <table aria-label="الباقات المحفوظة في المختبر">
        <thead><tr><th>الباقة</th><th>التنزيل</th><th>الرفع</th><th>الحالة</th><th>الإجراء</th></tr></thead>
        <tbody>
          {rows.length === 0 ? <tr><td colSpan={5}>
            {state.data
              ? state.data.loadedCount > 0 ? 'لا توجد باقات مطابقة للبحث.' : 'لا توجد باقات حتى الآن.'
              : 'لا توجد بيانات محملة'}
          </td></tr>
            : rows.map(plan => <tr key={plan.id}>
              <td>{plan.name}</td><td>{plan.downloadText}</td><td>{plan.uploadText}</td>
              <td><span className={plan.active ? 'pill good' : 'pill off'}>
                {plan.active ? 'مفعّل' : 'موقوف'}
              </span></td>
              <td><button type="button" className="btn subtle"
                onClick={() => window.dispatchEvent(new CustomEvent('radius-plan-edit', {
                  detail: plan,
                }))}>تعديل</button></td>
            </tr>)}
        </tbody>
      </table>
      <p className="table-caption" role="status">
        {state.data
          ? `المعروض ${state.data.visibleCount} من ${state.data.loadedCount} باقة محملة (حد القراءة: 100)`
          : 'سيتوفر العدد بعد قراءة البيانات.'}
      </p>
    </>
  );
}
