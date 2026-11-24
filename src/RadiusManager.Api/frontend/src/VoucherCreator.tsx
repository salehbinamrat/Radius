import { useEffect, useRef, useState, type FormEvent } from 'react';

type PlanOption = { id: string; name: string };
type CreateResult = { ok: boolean; shown?: boolean; error?: string };

/**
 * No password ever enters React state/props/events. The authenticated app
 * inserts the one-time response directly into this DOM ref, once, and sends
 * a secret-free visibility notification.
 */
export function VoucherCreator() {
  const [options, setOptions] = useState<PlanOption[]>([]);
  const [planId, setPlanId] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [hasCredentials, setHasCredentials] = useState(false);
  const secretRef = useRef<HTMLPreElement>(null);
  const generation = useRef(0);
  const currentView = useRef(false);

  useEffect(() => {
    currentView.current = document.getElementById('view-vouchers')?.hidden === false;
    const clear = () => {
      // Best-effort clearing of DOM content; JavaScript strings cannot be securely zeroized.
      generation.current += 1;
      if (secretRef.current) secretRef.current.textContent = '';
      setHasCredentials(false);
    };
    const onPlans = (event: Event) => {
      const detail = (event as CustomEvent<{ plans?: PlanOption[] }>).detail;
      const next = Array.isArray(detail?.plans) ? detail.plans : [];
      setOptions(next);
      setPlanId(previous => next.some(plan => plan.id === previous)
        ? previous : (next[0]?.id ?? ''));
    };
    const onView = (event: Event) => {
      const view = (event as CustomEvent<{ view?: string }>).detail?.view;
      currentView.current = view === 'vouchers';
      if (!currentView.current) clear();
    };
    const show = () => {
      if (currentView.current && secretRef.current?.textContent) {
        setHasCredentials(true);
      }
    };
    window.addEventListener('radius-voucher-creator-clear', clear);
    window.addEventListener('radius-voucher-created-visible', show);
    window.addEventListener('radius-voucher-plans-updated', onPlans);
    window.addEventListener('radius-view-changed', onView);
    window.dispatchEvent(new Event('radius-voucher-plans-request'));
    return () => {
      clear();
      window.removeEventListener('radius-voucher-creator-clear', clear);
      window.removeEventListener('radius-voucher-created-visible', show);
      window.removeEventListener('radius-voucher-plans-updated', onPlans);
      window.removeEventListener('radius-view-changed', onView);
    };
  }, []);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy) return;
    setError('');
    // The request first clears any earlier displayed credential, including
    // pending responses from an older request or a previous page visit.
    window.dispatchEvent(new Event('radius-voucher-secret-reset-request'));
    const startedGeneration = generation.current;
    if (!planId || !options.some(option => option.id === planId)) {
      setError('اختر باقة اختبار بدون حجم أو مدة.');
      return;
    }
    setBusy(true);
    try {
      const result = await new Promise<CreateResult>(resolve => {
        window.dispatchEvent(new CustomEvent('radius-voucher-create-request', {
          detail: {
            planId,
            isCurrent: () => generation.current === startedGeneration &&
              currentView.current &&
              document.getElementById('view-vouchers')?.hidden === false,
            respond: resolve,
          },
        }));
      });
      if (!result.ok) throw new Error(result.error || 'تعذر إنشاء كرت الاختبار.');
      if (!result.shown && currentView.current) {
        setError('تم إنشاء الكرت، لكن انتهت فرصة عرض كلمة المرور. لا يمكن استعادتها.');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'تعذر إنشاء كرت الاختبار.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <form id="labForm" className="form-stack"
        onSubmit={event => { void submit(event); }}>
        <label htmlFor="labPlan">باقة الكرت</label>
        <select id="labPlan" value={planId} required disabled={busy || options.length === 0}
          onChange={event => setPlanId(event.target.value)}>
          {options.length === 0 && <option value="">لا توجد باقات تجريبية مناسبة</option>}
          {options.map(option =>
            <option key={option.id} value={option.id}>{option.name}</option>)}
        </select>
        <button type="submit" className="btn primary" id="generateLab"
          disabled={busy || options.length === 0}>
          <svg className="ico" aria-hidden="true"><use href="#i-plus" /></svg>
          {busy ? 'جار إنشاء الكرت...' : 'إنشاء كرت اختبار'}
        </button>
      </form>
      <p id="labError" className="form-error" role="alert" aria-live="polite">{error}</p>
      <pre id="labCredentials" ref={secretRef} className="credentials"
        hidden={!hasCredentials} aria-live="polite" />
      <p className="section-note">ابق في هذه الشاشة حتى تظهر بيانات الدخول لمرة واحدة؛
        الانتقال إلى شاشة أخرى يمسحها ولا يمكن استعادتها من الواجهة.</p>
    </>
  );
}
