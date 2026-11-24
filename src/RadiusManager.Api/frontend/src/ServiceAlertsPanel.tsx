import { useState } from 'react';
import { useServiceMonitor } from './useServiceMonitor';
import { parseServiceIncidents } from '../../wwwroot/service-alert-model.mjs';

const names={postgresql:'PostgreSQL',freeradius:'FreeRADIUS'};
const labels={healthy:'استجابة مؤكدة',pending:'بانتظار تأكيد الفحص',failed:'فشل فحص مؤكد',unknown:'حالة غير مؤكدة'};
const severity={info:'معلومات',warning:'تحذير',critical:'حرج'};
const date=(value:string)=>new Date(value).toLocaleString('ar');
type Filter='all'|'open'|'closed';

export function ServiceAlertsPanel(){
  const {enabled,view}=useServiceMonitor('/api/service-status/incidents',parseServiceIncidents);
  const [filter,setFilter]=useState<Filter>('all');
  if (!enabled) return null;
  const incidents=view.data?.incidents??[];
  const open=incidents.filter(row=>row.recoveryConfirmedAtUtc===null).reverse();
  const closed=incidents.filter(row=>row.recoveryConfirmedAtUtc!==null)
    .sort((a,b)=>Date.parse(b.recoveryConfirmedAtUtc!)-Date.parse(a.recoveryConfirmedAtUtc!));
  const displayed=filter==='open'?open:filter==='closed'?closed:[...open,...closed];
  return <section className="surface-card service-alerts" data-alert-status={view.status} aria-labelledby="serviceAlertsTitle">
    <h2 id="serviceAlertsTitle">مركز تنبيهات الخدمات وأرشيف الأعطال</h2>
    <p className="section-note">تأكيد الفشل والاستعادة بفحصين مستقلين. انقطاع المراقبة لا يغلق الحادث ولا يثبت تعطل الخدمة.</p>
    {view.status!=='ready'||!view.data?<p role="status">{view.status==='loading'?'جار قراءة التنبيهات...'
      :view.status==='denied'?'لا توجد صلاحية لعرض التنبيهات.':'تعذر تحديث التنبيهات؛ لا تعرض حالة سابقة على أنها حالية.'}</p>:<>
      <div className="alert-services" aria-live="polite">
        {view.data.services.map(row=><article className="alert-service" key={row.service}
          data-alert-service={row.service} data-alert-state={row.state} data-alert-severity={row.severity}>
          <span>{names[row.service]} — {severity[row.severity]}</span>
          <strong>{labels[row.state]}</strong>
          <small>{row.lastEvidenceAtUtc?'آخر دليل: '+date(row.lastEvidenceAtUtc):'لا يوجد دليل حديث مؤكد'}</small>
        </article>)}
      </div>
      <p className="section-note" data-incident-retention={view.data.retention}>
        {view.data.retention==='volume-snapshot'?'الحفظ المحلي فعال؛ آخر 256 حادثا مغلقا وجميع الحوادث المفتوحة.'
          :view.data.retention==='storage-degraded'?'تعذر الحفظ الدائم؛ الأرشيف الحالي غير مضمون بعد إعادة التشغيل.'
          :'الأرشيف في الذاكرة فقط؛ لا يستمر بعد إعادة التشغيل.'}
      </p>
      <div className="incident-toolbar">
        <h3>أرشيف الحوادث — مفتوحة: {open.length} / مغلقة: {closed.length}</h3>
        <label>عرض الحوادث <select value={filter} onChange={event=>setFilter(event.target.value as Filter)}>
          <option value="all">الكل</option><option value="open">المفتوحة</option><option value="closed">المغلقة</option>
        </select></label>
      </div>
      {displayed.length===0?<p className="section-note" data-incidents-empty>لا توجد حوادث في هذا العرض. لا يثبت ذلك عدم وقوع أعطال.</p>:
        <div className="incident-table-wrap"><table aria-label="أرشيف الحوادث">
          <thead><tr><th>الخدمة</th><th>الحالة</th><th>تأكيد الفشل</th><th>تأكيد الاستعادة</th><th>معرف الحادث</th></tr></thead>
          <tbody>{displayed.map(row=><tr key={row.id} data-incident-state={row.recoveryConfirmedAtUtc?'closed':'open'}>
            <td>{names[row.service]}</td><td>{row.recoveryConfirmedAtUtc?'مغلق':'مفتوح'}</td>
            <td>{date(row.failureConfirmedAtUtc)}</td><td>{row.recoveryConfirmedAtUtc?date(row.recoveryConfirmedAtUtc):'لم تؤكد الاستعادة'}</td>
            <td><code dir="ltr">{row.id}</code></td>
          </tr>)}</tbody>
        </table></div>}
      <p className="section-note">الأوقات هي أوقات تأكيد الفحوص لا بداية الانقطاع الفعلية أو مدته. لا إشعارات خارجية أو إجراءات على MikroTik.</p>
    </>}
  </section>;
}
