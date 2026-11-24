import { useEffect, useState } from 'react';
import { parseServiceHistory, historyMetrics, latencySegments, type ServiceHistory } from '../../wwwroot/service-history-model.mjs';

type State = {status:'loading'|'ready'|'error'|'denied';data:ServiceHistory|null};
const initial:State={status:'loading',data:null};
const labels = {reachable:'استجاب',responsive:'استجاب','no-response':'لم يستجب',unknown:'غير مؤكد'};
const format = (n:number|null) => n===null?'—':n.toLocaleString('en-US',{maximumFractionDigits:2});
function cssState(state:string) { return state==='no-response'?'history-bad':state==='unknown'?'':'history-good'; }

export function ServiceHistoryPanel() {
  const [enabled,setEnabled]=useState(false);
  const [view,setView]=useState<State>(initial);
  useEffect(()=>{
    const scope=(event:Event)=>{
      const active=(event as CustomEvent<{enabled?:boolean}>).detail?.enabled===true && location.protocol==='https:';
      setEnabled(active);
      if (!active) setView(initial);
    };
    const logout=()=>{setEnabled(false);setView(initial);};
    window.addEventListener('radius-live-status-scope',scope);
    window.addEventListener('radius-session-logged-out',logout);
    window.dispatchEvent(new Event('radius-live-status-request'));
    return ()=>{
      window.removeEventListener('radius-live-status-scope',scope);
      window.removeEventListener('radius-session-logged-out',logout);
    };
  },[]);
  useEffect(()=>{
    if (!enabled) return;
    let disposed=false;
    let timer:ReturnType<typeof setTimeout>|undefined;
    let controller:AbortController|undefined;
    async function read(){
      controller=new AbortController();
      const timeout=setTimeout(()=>controller?.abort(),5000);
      let denied=false;
      try {
        const response=await fetch('/api/service-status/history',{credentials:'same-origin',cache:'no-store',signal:controller.signal});
        if (disposed) return;
        if (response.status===401||response.status===403) {
          denied=true;setView({status:'denied',data:null});return;
        }
        if (!response.ok) throw new Error('history');
        const data=parseServiceHistory(await response.json());
        if (!data) throw new Error('history');
        if (!disposed) setView({status:'ready',data});
      } catch {
        if (!disposed) setView({status:'error',data:null});
      } finally {
        clearTimeout(timeout);
        if (!disposed&&!denied) timer=setTimeout(()=>{void read();},15000);
      }
    }
    setView(initial);void read();
    return ()=>{disposed=true;clearTimeout(timer);controller?.abort();};
  },[enabled]);
  if (!enabled) return null;
  const samples=view.data?.samples??[];
  const metrics=historyMetrics(samples);
  const segments=latencySegments(samples);
  const start=samples.length?Date.parse(samples[0].observedAtUtc):0;
  const end=samples.length?Date.parse(samples[samples.length-1].observedAtUtc):start;
  const ymax=Math.max(1,...segments.flatMap(segment=>segment.map(p=>p.ms)));
  const x=(t:number)=>42+540*(t-start)/Math.max(1,end-start);
  const y=(ms:number)=>116-94*ms/ymax;
  return <section className="surface-card service-history" data-history-status={view.status} data-history-count={samples.length}
    aria-labelledby="serviceHistoryTitle">
    <h2 id="serviceHistoryTitle">سجل مراقبة الخدمات</h2>
    <p className="section-note">آخر 240 عينة في ذاكرة API (نحو ساعة). يعاد السجل عند تشغيل الخدمة مجددا، ولا يمثل نسبة التوفر أو مدة الانقطاع.</p>
    {view.status!=='ready'?<p role="status">{view.status==='loading'?'جار قراءة سجل المراقبة...':view.status==='denied'?'لا توجد صلاحية لعرض السجل.':'تعذر قراءة سجل المراقبة. لا تعرض بيانات قديمة.'}</p>:
      samples.length===0?<p role="status">لا توجد عينات مسجلة بعد.</p>:<>
      <div className="history-summary">
        <div className="history-stat">عدد العينات<strong>{metrics.count}</strong></div>
        <div className="history-stat">متوسط زمن فحص PostgreSQL<strong>{format(metrics.mean)} ms</strong></div>
        <div className="history-stat">عينات فشل PostgreSQL<strong>{metrics.databaseFailures}</strong></div>
        <div className="history-stat">عينات فشل FreeRADIUS<strong>{metrics.radiusFailures}</strong></div>
        <div className="history-stat">عينات غير مؤكدة<strong>{metrics.unknown}</strong></div>
      </div>
      <svg className="history-chart" viewBox="0 0 610 146" role="img" aria-label="زمن استعلام PostgreSQL بالمللي ثانية، الفجوات غير موصولة" direction="ltr">
        {[0,.5,1].map(v=><g key={v}><line className="history-grid" x1={42} x2={582} y1={y(ymax*v)} y2={y(ymax*v)}/>
          <text x={38} y={y(ymax*v)+4} textAnchor="end" fontSize="10" fill="currentColor">{format(ymax*v)}</text></g>)}
        {segments.map((segment,i)=><g key={i}>
          {segment.length>1&&<polyline className="history-line" points={segment.map(p=>x(p.time)+','+y(p.ms)).join(' ')}/>}
          {segment.map((p,j)=><circle key={j} className="history-point" cx={x(p.time)} cy={y(p.ms)} r="2"/>)}
        </g>)}
        <text x={42} y={138} fontSize="10" fill="currentColor">{new Date(start).toLocaleTimeString('en-GB')}</text>
        <text x={582} y={138} textAnchor="end" fontSize="10" fill="currentColor">{new Date(end).toLocaleTimeString('en-GB')}</text>
      </svg>
      <p className="section-note">الرسم يعرض قياسات الاستعلام الناجحة فقط. لا يوصل الفجوات أو الفحوص الفاشلة.</p>
      <div className="history-table-wrap"><table aria-label="آخر 30 عينة مراقبة">
        <thead><tr><th>وقت الرصد المحلي</th><th>PostgreSQL</th><th>الزمن (ms)</th><th>FreeRADIUS</th></tr></thead>
        <tbody>{samples.slice(-30).reverse().map((row,i)=><tr key={row.observedAtUtc+'-'+i}>
          <td>{new Date(row.observedAtUtc).toLocaleString('ar')}</td>
          <td className={cssState(row.database)}>{labels[row.database]}</td><td>{format(row.databaseCheckMs)}</td>
          <td className={cssState(row.radius)}>{labels[row.radius]}</td>
        </tr>)}</tbody>
      </table></div>
      </>}
  </section>;
}
