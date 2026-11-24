import { useEffect, useState } from 'react';

type Voucher={username:string;planName:string;active:boolean;createdAt:string;disabledAt:string|null};
type Snapshot={accounts:Voucher[];hasMore:boolean};
type View={status:'loading'|'ready'|'error'|'denied';data:Snapshot|null};
const object=(x:unknown):x is Record<string,unknown>=>typeof x==='object'&&x!==null&&!Array.isArray(x);
const exact=(x:unknown,keys:string[]):x is Record<string,unknown>=>object(x)&&Object.keys(x).length===keys.length&&keys.every(k=>Object.hasOwn(x,k));
const utc=(x:unknown):x is string=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|\+00:00)$/.test(x)&&Number.isFinite(Date.parse(x));

function parse(value:unknown):Snapshot|null{
  if(!exact(value,['accounts','hasMore','limit','labOnly'])||value.labOnly!==true||value.limit!==100
    ||typeof value.hasMore!=='boolean'||!Array.isArray(value.accounts)||value.accounts.length>100
    ||(value.hasMore&&value.accounts.length!==100))return null;
  const accounts:Voucher[]=[];
  const ids=new Set<string>();
  for(const row of value.accounts){
    if(!exact(row,['username','planName','active','createdAt','disabledAt'])
      ||typeof row.username!=='string'||row.username.length!==16||!/^lab_[a-f0-9]{12}$/.test(row.username)
      ||ids.has(row.username)||typeof row.planName!=='string'||typeof row.active!=='boolean'
      ||!utc(row.createdAt)||!(row.disabledAt===null||utc(row.disabledAt))
      ||row.active!==(row.disabledAt===null))return null;
    ids.add(row.username);
    accounts.push({username:row.username,planName:row.planName,active:row.active,createdAt:row.createdAt,disabledAt:row.disabledAt});
  }
  return {accounts,hasMore:value.hasMore};
}

export function ResellerWorkspace(){
  const [enabled,setEnabled]=useState(false);
  useEffect(()=>{
    const scope=(event:Event)=>setEnabled(location.protocol==='https:'
      &&(event as CustomEvent<{enabled?:boolean}>).detail?.enabled===true);
    const logout=()=>setEnabled(false);
    window.addEventListener('radius-reseller-scope',scope);
    window.addEventListener('radius-session-logged-out',logout);
    window.dispatchEvent(new Event('radius-reseller-request'));
    return ()=>{
      window.removeEventListener('radius-reseller-scope',scope);
      window.removeEventListener('radius-session-logged-out',logout);
    };
  },[]);
  return enabled?<ResellerAccounts/>:null;
}

function ResellerAccounts(){
  const [view,setView]=useState<View>({status:'loading',data:null});
  const [search,setSearch]=useState('');
  const [filter,setFilter]=useState('all');
  const [refresh,setRefresh]=useState(0);
  useEffect(()=>{
    let disposed=false;
    let controller:AbortController|undefined;
    let timer:ReturnType<typeof setTimeout>|undefined;
    async function load(){
      if(disposed)return;
      controller=new AbortController();
      const request=controller;
      const timeout=setTimeout(()=>request.abort(),5000);
      let denied=false;
      setView({status:'loading',data:null});
      try{
        const response=await fetch('/api/reseller/accounts',{credentials:'same-origin',cache:'no-store',signal:request.signal});
        if(disposed)return;
        if(response.status===401||response.status===403){
          denied=true;setView({status:'denied',data:null});
          if(response.status===401)window.dispatchEvent(new Event('radius-reseller-expired'));
          return;
        }
        if(!response.ok)throw new Error('read');
        const data=parse(await response.json());
        if(!data)throw new Error('contract');
        if(!disposed)setView({status:'ready',data});
      }catch{
        if(!disposed)setView({status:'error',data:null});
      }finally{
        clearTimeout(timeout);
        if(!disposed&&!denied)timer=setTimeout(()=>{void load();},15000);
      }
    }
    void load();
    return ()=>{disposed=true;clearTimeout(timer);controller?.abort();};
  },[refresh]);
  const date=(x:string)=>new Date(x).toLocaleString('ar');
  const query=search.trim().toLowerCase();
  const accounts=view.data?.accounts??[];
  const rows=accounts.filter(row=>(filter==='all'||row.active===(filter==='active'))
    &&(!query||row.username.includes(query)||row.planName.toLowerCase().includes(query)));
  return <section className="surface-card reseller-panel" data-reseller-status={view.status} aria-labelledby="resellerAccountsTitle">
    <h2 id="resellerAccountsTitle">الكروت التابعة لحسابك</h2>
    <p className="section-note">قراءة فقط من سجلات المختبر. يتم تحديث الملكية من الخادم، ولا تعرض كلمات المرور.</p>
    {view.status==='loading'?<p role="status">جار قراءة الكروت المملوكة...</p>:
      view.status==='denied'?<p role="alert">لا توجد صلاحية لعرض الكروت. سجل الخروج ثم تحقق من دورك.</p>:
      view.status==='error'?<p role="alert">تعذر قراءة البيانات الحالية. لا تعرض نتائج قديمة.</p>:view.data&&<>
        <div className="reseller-summary">
          <div className="reseller-stat">الكروت المحملة<strong>{accounts.length}</strong></div>
          <div className="reseller-stat">نشطة في القائمة<strong>{accounts.filter(x=>x.active).length}</strong></div>
          <div className="reseller-stat">معطلة في القائمة<strong>{accounts.filter(x=>!x.active).length}</strong></div>
        </div>
        <p className="section-note">{view.data.hasMore?'هذه أول 100 كرت فقط، وليست إجمالي ملكيتك.':'جميع الكروت التي أعادها الخادم ضمن الحد الحالي.'} الحالة النشطة لا تعني أن الكرت متصل الآن.</p>
        <div className="reseller-toolbar">
          <label>بحث في القائمة<input id="resellerSearch" type="search" value={search} onChange={e=>setSearch(e.target.value)}/></label>
          <label>الحالة<select id="resellerFilter" value={filter} onChange={e=>setFilter(e.target.value)}>
            <option value="all">الكل</option><option value="active">نشطة</option><option value="disabled">معطلة</option>
          </select></label>
        </div>
        {!rows.length?<p role="status">لا توجد كروت مطابقة في القائمة الحالية.</p>:<div className="table-wrap"><table aria-label="الكروت التابعة للوكيل">
          <thead><tr><th>رقم الكرت</th><th>الباقة</th><th>الحالة</th><th>تاريخ الإنشاء</th><th>تاريخ التعطيل</th></tr></thead>
          <tbody>{rows.map(row=><tr key={row.username} data-reseller-card={row.username}>
            <td dir="ltr">{row.username}</td><td>{row.planName}</td><td>{row.active?'نشط':'معطل'}</td>
            <td>{date(row.createdAt)}</td><td>{row.disabledAt?date(row.disabledAt):'—'}</td>
          </tr>)}</tbody>
        </table></div>}
      </>}
    {view.status!=='denied'&&<button id="resellerRefresh" className="btn subtle" type="button"
      disabled={view.status==='loading'} onClick={()=>setRefresh(n=>n+1)}>تحديث القائمة</button>}
  </section>;
}
