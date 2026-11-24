import { useServiceMonitor } from './useServiceMonitor';
import { parseServiceAlerts } from '../../wwwroot/service-alert-model.mjs';

const names={postgresql:'PostgreSQL',freeradius:'FreeRADIUS'};
const labels={healthy:'استجابة مؤكدة',pending:'بانتظار تأكيد الفحص',failed:'فشل فحص مؤكد',unknown:'حالة غير مؤكدة'};
const severity={info:'معلومات',warning:'تحذير',critical:'حرج'};

export function ServiceAlertsPanel(){
  const {enabled,view}=useServiceMonitor('/api/service-status/alerts',parseServiceAlerts);
  if (!enabled) return null;
  const events=view.data?.events??[];
  return <section className="surface-card service-alerts" data-alert-status={view.status} aria-labelledby="serviceAlertsTitle">
    <h2 id="serviceAlertsTitle">مركز تنبيهات الخدمات</h2>
    <p className="section-note">تأكيد الفشل والاستعادة بفحصين مستقلين. الأحداث من نافذة الرصد المحفوظة فقط، وليست أرشيفا دائما للحوادث.</p>
    {view.status!=='ready'||!view.data?<p role="status">{view.status==='loading'?'جار قراءة التنبيهات...'
      :view.status==='denied'?'لا توجد صلاحية لعرض التنبيهات.':'تعذر تحديث التنبيهات؛ لا تعرض حالة سابقة على أنها حالية.'}</p>:<>
      <div className="alert-services" aria-live="polite">
        {view.data.services.map(row=><article className="alert-service" key={row.service}
          data-alert-service={row.service} data-alert-state={row.state} data-alert-severity={row.severity}>
          <span>{names[row.service]} — {severity[row.severity]}</span>
          <strong>{labels[row.state]}</strong>
          <small>{row.lastEvidenceAtUtc?'آخر دليل: '+new Date(row.lastEvidenceAtUtc).toLocaleString('ar'):'لا يوجد دليل حديث مؤكد'}</small>
        </article>)}
      </div>
      <h3>آخر أحداث الفشل والاستعادة</h3>
      {events.length===0?<p className="section-note">لا توجد أحداث مؤكدة ضمن العينات الحالية. هذا لا يثبت عدم وقوع أعطال.</p>:
        <div className="alert-events" role="list">
          {events.slice(-30).reverse().map((row,i)=><div className="alert-event" role="listitem" key={row.service+row.kind+row.confirmedAtUtc+i}>
            <span>{names[row.service]} — {row.kind==='failure-confirmed'?'تأكيد فشل الفحص':'تأكيد استعادة الاستجابة'}</span>
            <time dateTime={row.confirmedAtUtc}>{new Date(row.confirmedAtUtc).toLocaleString('ar')}</time>
          </div>)}
        </div>}
      <p className="section-note">يعرض آخر 30 حدثا من النافذة الحالية. لا يرسل إشعارات خارجية ولا ينفذ إجراءات على MikroTik.</p>
    </>}
  </section>;
}
