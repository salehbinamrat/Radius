import { useMemo, useState, type FormEvent } from 'react';
import { estimateCapacity } from '../../wwwroot/capacity-utils.mjs';

type Fields = {
  users: string;
  averageMbps: string;
  peakConcurrencyPercent: string;
  contentionRatio: string;
  dailyPeakEquivalentHours: string;
};
const defaults: Fields = {
  users: '800',
  averageMbps: '6',
  peakConcurrencyPercent: '45',
  contentionRatio: '8',
  dailyPeakEquivalentHours: '6',
};
type FieldName = keyof Fields;

function Metric({ title, id, value }: { title: string; id: string; value: string }) {
  return <div className="ultra-cap"><span>{title}</span><strong id={id}>{value}</strong></div>;
}

/**
 * Offline what-if calculator only. It imports the original tested JS engine;
 * no request, telemetry or router command is performed by this component.
 */
export function CapacityCalculator() {
  const [fields, setFields] = useState<Fields>(defaults);

  const calculation = useMemo(() => {
    try {
      const result = estimateCapacity({
        users: Number(fields.users),
        averageMbps: Number(fields.averageMbps),
        peakConcurrencyPercent: Number(fields.peakConcurrencyPercent),
        contentionRatio: Number(fields.contentionRatio),
        dailyPeakEquivalentHours: Number(fields.dailyPeakEquivalentHours),
      });
      return { result, error: '' };
    } catch (error) {
      return {
        result: null,
        error: error instanceof Error ? error.message : 'تعذر حساب السيناريو.',
      };
    }
  }, [fields]);

  function update(field: FieldName, value: string) {
    setFields(previous => ({ ...previous, [field]: value }));
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); // Results are calculated locally whenever an assumption changes.
  }

  const result = calculation.result;
  return (
    <>
      <section className="surface-card">
        <div className="section-title"><div><span className="eyebrow">الافتراضات</span><h2>مدخلات التخطيط</h2></div></div>
        <form id="capForm" onSubmit={submit}>
          <div className="ultra-form-grid">
            <label>إجمالي المشتركين
              <input id="capUsers" type="number" min={1} max={1000000} step={1} required
                inputMode="numeric" value={fields.users}
                onChange={event => update('users', event.target.value)} />
            </label>
            <label>متوسط السرعة Mbps
              <input id="capSpeed" type="number" min={0.1} max={10000} step={0.1} required
                inputMode="decimal" value={fields.averageMbps}
                onChange={event => update('averageMbps', event.target.value)} />
            </label>
            <label>نسبة التزامن وقت الذروة %
              <input id="capConcurrency" type="number" min={1} max={100} step={1} required
                inputMode="numeric" value={fields.peakConcurrencyPercent}
                onChange={event => update('peakConcurrencyPercent', event.target.value)} />
            </label>
            <label>معامل المشاركة 1:X
              <input id="capSharing" type="number" min={1} max={1000} step={1} required
                inputMode="numeric" value={fields.contentionRatio}
                onChange={event => update('contentionRatio', event.target.value)} />
            </label>
            <label>الساعات المكافئة لذروة الاستهلاك يوميا
              <input id="capHours" type="number" min={0.5} max={24} step={0.5} required
                inputMode="decimal" value={fields.dailyPeakEquivalentHours}
                onChange={event => update('dailyPeakEquivalentHours', event.target.value)} />
            </label>
          </div>
          <p id="capError" className="form-error" role="alert" aria-live="polite">{calculation.error}</p>
          <button type="submit" className="btn primary">حساب السيناريو</button>
        </form>
      </section>
      <section className="surface-card">
        <div className="section-title"><div><span className="eyebrow">النتائج</span><h2>التقدير الافتراضي</h2></div></div>
        <div id="capResults" className="ultra-caps" hidden={!result} aria-live="polite">
          <Metric id="capPeakOut" title="المستخدمون المتزامنون المتوقعون"
            value={result ? result.peakUsers.toLocaleString('en-US') : '—'} />
          <Metric id="capSpeedOut" title="سعة الإنترنت المقدرة"
            value={result ? `${result.upstreamMbps.toLocaleString('en-US')} Mbps` : '—'} />
          <Metric id="capVolumeOut" title="البيانات الشهرية (TB عشرية)"
            value={result ? `${result.monthlyDecimalTb.toLocaleString('en-US')} TB` : '—'} />
        </div>
        <p className="ultra-note">طريقة الحساب: المتزامنون = المستخدمون × نسبة الذروة؛ السعة = المتزامنون × سرعة الباقة ÷ معامل المشاركة؛ الاستهلاك = السعة × ساعات الذروة المكافئة × 30 يوما. لا يأخذ هذا التقدير في الحسبان تأخر Starlink أو التذبذب أو عدد الاتصالات الفعلي.</p>
      </section>
    </>
  );
}
