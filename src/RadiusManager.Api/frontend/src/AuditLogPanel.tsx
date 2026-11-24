import {useEffect,useState,type FormEvent} from 'react';

const actions:Record<string,string>={
  bootstrap_admin:'إنشاء المسؤول الأول',login_success:'دخول ناجح',login_failure:'دخول مرفوض',logout:'خروج',
  password_changed:'تغيير كلمة المرور',password_change_rejected:'رفض تغيير كلمة المرور',
  plan_created:'إنشاء باقة',plan_updated:'تعديل باقة',voucher_created:'إنشاء كرت',voucher_disabled:'تعطيل كرت',
  nas_draft_created:'إنشاء مسودة NAS',nas_draft_retired:'إغلاق مسودة NAS',
  voucher_owner_assigned:'إسناد ملكية',voucher_owner_transferred:'نقل ملكية'
};
const outcomes:Record<string,string>={success:'ناجح',denied:'مرفوض',error:'خطأ'};
type Filters={action:string;outcome:string;actor:string;from:string;to:string};
const empty:Filters={action:'',outcome:'',actor:'',from:'',to:''};
type EventRow={id:string;actorId:string|null;action:string;subjectKind:string|null;subjectId:string|null;outcome:string;occurredAt:string;correlationId:string};
type Page={events:EventRow[];nextBefore:string|null};
const object=(x:unknown):x is Record<string,unknown>=>typeof x==='object'&&x!==null&&!Array.isArray(x);
const exact=(x:unknown,keys:string[]):x is Record<string,unknown>=>object(x)&&Object.keys(x).length===keys.length&&keys.every(k=>Object.hasOwn(x,k));
const id=(x:unknown):x is string=>typeof x==='string'&&/^[1-9][0-9]{0,18}$/.test(x)&&x.length<=19&&BigInt(x)<=9223372036854775807n;
const nullable=(x:unknown,max:number):x is string|null=>x===null||typeof x==='string'&&x.length<=max;
function parse(x:unknown):Page|null{
  if(!exact(x,['events','nextBefore','limit','labOnly'])||x.labOnly!==true||x.limit!==50
    ||!Array.isArray(x.events)||x.events.length>50||!(x.nextBefore===null||id(x.nextBefore)))return null;
  const rows:EventRow[]=[];
  for(const r of x.events){
    if(!exact(r,['id','actorId','action','subjectKind','subjectId','outcome','occurredAt','correlationId'])
      ||!id(r.id)||!nullable(r.actorId,160)||typeof r.action!=='string'||!Object.hasOwn(actions,r.action)
      ||!nullable(r.subjectKind,64)||!nullable(r.subjectId,160)||typeof r.outcome!=='string'||!Object.hasOwn(outcomes,r.outcome)
      ||typeof r.occurredAt!=='string'||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|\+00:00)$/.test(r.occurredAt)
      ||!Number.isFinite(Date.parse(r.occurredAt))||typeof r.correlationId!=='string'||!/^[0-9a-f-]{36}$/i.test(r.correlationId)
      ||(rows.length>0&&BigInt(rows[rows.length-1].id)<=BigInt(r.id)))return null;
    rows.push({id:r.id,actorId:r.actorId,action:r.action,subjectKind:r.subjectKind,subjectId:r.subjectId,
      outcome:r.outcome,occurredAt:r.occurredAt,correlationId:r.correlationId});
  }
  if(x.nextBefore!==null&&(rows.length!==50||rows[49].id!==x.nextBefore))return null;
  return {events:rows,nextBefore:x.nextBefore};
}

export function AuditLogPanel(){
  const [enabled,setEnabled]=useState(false);
  useEffect(()=>{
    const scope=(e:Event)=>setEnabled(location.protocol==='https:'&&(e as CustomEvent<{auditEnabled?:boolean}>).detail?.auditEnabled===true);
    const logout=()=>setEnabled(false);
    window.addEventListener('radius-live-status-scope',scope);
    window.addEventListener('radius-session-logged-out',logout);
    window.dispatchEvent(new Event('radius-live-status-request'));
    return ()=>{window.removeEventListener('radius-live-status-scope',scope);window.removeEventListener('radius-session-logged-out',logout);};
  },[]);
  return enabled?<AuditTable/>:null;
}
function AuditTable(){
  const [draft,setDraft]=useState<Filters>(empty);
  const [query,setQuery]=useState<{filters:Filters;before:string|null}>({filters:empty,before:null});
  const [page,setPage]=useState<Page|null>(null);
  const [state,setState]=useState('loading');
  useEffect(()=>{
    let disposed=false;
    const c=new AbortController();
    const timeout=setTimeout(()=>c.abort(),8000);
    setPage(null);setState('loading');
    const p=new URLSearchParams();
    for(const [k,v] of Object.entries(query.filters))if(v)p.set(k,v);
    if(query.before)p.set('before',query.before);
    async function load(){
      try{
        const r=await fetch('/api/admin-audit?'+p.toString(),{credentials:'same-origin',cache:'no-store',signal:c.signal});
        if(disposed)return;
        if(r.status===401||r.status===403){setState('denied');return;}
        if(!r.ok)throw new Error('read');
        const parsed=parse(await r.json());
        if(!parsed)throw new Error('contract');
        if(!disposed){setPage(parsed);setState('ready');}
      }catch{if(!disposed)setState('error');}
      finally{clearTimeout(timeout);}
    }
    void load();
    return ()=>{disposed=true;clearTimeout(timeout);c.abort();};
  },[query]);
  const change=(key:keyof Filters,value:string)=>setDraft(old=>({...old,[key]:value}));
  function search(e:FormEvent){e.preventDefault();setQuery({filters:{...draft,actor:draft.actor.trim()},before:null});}
  return <section className="surface-card audit-panel" data-audit-state={state}>
    <h2>مراجعة الأحداث الإدارية</h2>
    <p className="section-note">آخر الأحداث المسجلة حسب معرف التسجيل. التواريخ المرشحة بتوقيت UTC. لا يعرض هذا السجل كل المحاولات المرفوضة بعد.</p>
    {state==='denied'?<p role="alert">لا توجد صلاحية لقراءة السجل. أعد تسجيل الدخول.</p>:<>
      <form className="audit-filters" onSubmit={search}>
        <label>العملية<select id="auditAction" value={draft.action} onChange={e=>change('action',e.target.value)}><option value="">الكل</option>{Object.entries(actions).map(([k,v])=><option key={k} value={k}>{v}</option>)}</select></label>
        <label>النتيجة<select id="auditOutcome" value={draft.outcome} onChange={e=>change('outcome',e.target.value)}><option value="">الكل</option>{Object.entries(outcomes).map(([k,v])=><option key={k} value={k}>{v}</option>)}</select></label>
        <label>معرف المسؤول<input value={draft.actor} maxLength={160} onChange={e=>change('actor',e.target.value)}/></label>
        <label>من تاريخ<input type="date" min="2000-01-01" max="9998-12-31" value={draft.from} onChange={e=>change('from',e.target.value)}/></label>
        <label>إلى تاريخ<input type="date" min={draft.from||'2000-01-01'} max="9998-12-31" value={draft.to} onChange={e=>change('to',e.target.value)}/></label>
        <button id="auditApply" type="submit" className="btn primary" disabled={state==='loading'}>بحث</button>
      </form>
      {state==='loading'?<p role="status">جار قراءة السجل...</p>:state==='error'?<p role="alert">تعذر قراءة السجل. تحقق من المرشحات وأعد البحث.</p>:page&&<>
        <p role="status">عدد الأحداث في الصفحة: {page.events.length}</p>
        {page.events.length===0?<p>لا توجد أحداث مطابقة.</p>:<div className="audit-table"><table aria-label="سجل التدقيق الأمني"><thead><tr><th>المعرف</th><th>العملية</th><th>المسؤول</th><th>المورد</th><th>النتيجة</th><th>التوقيت UTC</th><th>معرف الارتباط</th></tr></thead><tbody>
          {page.events.map(r=><tr key={r.id} data-audit-action={r.action}><td>{r.id}</td><td>{actions[r.action]}</td><td dir="ltr">{r.actorId??'—'}</td><td>{r.subjectKind??'—'} / <span dir="ltr">{r.subjectId??'—'}</span></td><td>{outcomes[r.outcome]}</td><td dir="ltr">{r.occurredAt}</td><td dir="ltr">{r.correlationId}</td></tr>)}
        </tbody></table></div>}
        <div className="audit-buttons"><button className="btn subtle" type="button" onClick={()=>setQuery({filters:query.filters,before:null})}>الأحدث / تحديث</button>
        <button className="btn subtle" type="button" disabled={!page.nextBefore} onClick={()=>setQuery({filters:query.filters,before:page.nextBefore})}>الأحداث الأقدم</button></div>
      </>}
    </>}
  </section>;
}
