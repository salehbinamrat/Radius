import { useEffect, useRef, useState, type FormEvent } from 'react';

type Account={username:string;planName:string};
type Reseller={id:string;username:string|null};
type Choices={accounts:Account[];resellers:Reseller[];limited:boolean};
type State='loading'|'ready'|'error'|'denied';
const isObject=(x:unknown):x is Record<string,unknown>=>typeof x==='object'&&x!==null&&!Array.isArray(x);
const exact=(x:unknown,keys:string[]):x is Record<string,unknown>=>isObject(x)&&Object.keys(x).length===keys.length&&keys.every(k=>Object.hasOwn(x,k));
const labName=(x:unknown):x is string=>typeof x==='string'&&x.length===16&&/^lab_[a-f0-9]{12}$/.test(x);
const ownerId=(x:unknown):x is string=>typeof x==='string'&&x.length>0&&x.length<=160&&x.trim()===x&&!/[\x00-\x1f\x7f]/.test(x);

function parseList<T>(value:unknown,key:string,parse:(row:unknown)=>T|null):{rows:T[];more:boolean}|null{
  if(!exact(value,[key,'hasMore','limit','labOnly'])||value.labOnly!==true||value.limit!==100
    ||typeof value.hasMore!=='boolean')return null;
  const list=value[key];
  if(!Array.isArray(list)||list.length>100)return null;
  const rows:T[]=[];
  for(const item of list){const row=parse(item);if(row===null)return null;rows.push(row);}
  return {rows,more:value.hasMore};
}
const parseAccount=(x:unknown):Account|null=>exact(x,['username','planName'])&&labName(x.username)
  &&typeof x.planName==='string'?{username:x.username,planName:x.planName}:null;
const parseReseller=(x:unknown):Reseller|null=>exact(x,['id','username'])&&ownerId(x.id)
  &&(x.username===null||typeof x.username==='string')?{id:x.id,username:x.username}:null;
async function readJson(path:string,signal:AbortSignal){
  const res=await fetch(path,{credentials:'same-origin',cache:'no-store',signal});
  if(res.status===401||res.status===403)throw new Error('denied');
  if(!res.ok)throw new Error('unavailable');
  return await res.json() as unknown;
}

export function OwnershipPanel(){
  const [enabled,setEnabled]=useState(false);
  useEffect(()=>{
    const scope=(event:Event)=>setEnabled(location.protocol==='https:'
      &&(event as CustomEvent<{ownershipEnabled?:boolean}>).detail?.ownershipEnabled===true);
    const logout=()=>setEnabled(false);
    window.addEventListener('radius-live-status-scope',scope);
    window.addEventListener('radius-session-logged-out',logout);
    window.dispatchEvent(new Event('radius-live-status-request'));
    return ()=>{
      window.removeEventListener('radius-live-status-scope',scope);
      window.removeEventListener('radius-session-logged-out',logout);
    };
  },[]);
  return enabled?<OwnershipForm/>:null;
}

function OwnershipForm(){
  const [state,setState]=useState<State>('loading');
  const [choices,setChoices]=useState<Choices|null>(null);
  const [card,setCard]=useState('');
  const [owner,setOwner]=useState('');
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState('');
  const [refresh,setRefresh]=useState(0);
  const active=useRef<AbortController|null>(null);
  const submitting=useRef(false);
  useEffect(()=>{
    const controller=new AbortController();
    active.current=controller;
    const timeout=setTimeout(()=>controller.abort(),10000);
    let disposed=false;
    setState('loading');setChoices(null);setCard('');setOwner('');
    async function load(){
      try{
        // Sequential first authorization check: never fetch the account list if denied.
        const r=parseList(await readJson('/api/ownership/resellers',controller.signal),'resellers',parseReseller);
        if(!r)throw new Error('invalid');
        const a=parseList(await readJson('/api/ownership/accounts',controller.signal),'accounts',parseAccount);
        if(!a||new Set(a.rows.map(x=>x.username)).size!==a.rows.length
          ||new Set(r.rows.map(x=>x.id)).size!==r.rows.length)throw new Error('invalid');
        if(!disposed){setChoices({accounts:a.rows,resellers:r.rows,limited:a.more||r.more});setState('ready');}
      }catch(err){
        if(!disposed)setState(err instanceof Error&&err.message==='denied'?'denied':'error');
      }finally{clearTimeout(timeout);}
    }
    void load();
    return ()=>{disposed=true;clearTimeout(timeout);controller.abort();};
  },[refresh]);
  async function submit(event:FormEvent<HTMLFormElement>){
    event.preventDefault();
    if(submitting.current||state!=='ready'||!choices||!choices.accounts.some(x=>x.username===card)
      ||!choices.resellers.some(x=>x.id===owner))return;
    const selected=choices.resellers.find(x=>x.id===owner);
    if(!window.confirm('إسناد الكرت '+card+' إلى '+(selected?.username??owner)+'؟ لا يمكن إعادة إسناده من هذه الواجهة.'))return;
    const controller=active.current;
    if(!controller||controller.signal.aborted)return;
    submitting.current=true;setBusy(true);setMessage('');
    const timeout=setTimeout(()=>controller.abort(),10000);
    let sent=false;
    try{
      const csrf=await readJson('/api/admin/auth/csrf',controller.signal);
      if(!isObject(csrf)||typeof csrf.requestToken!=='string'||csrf.requestToken.length<20)throw new Error('invalid');
      sent=true;
      const response=await fetch('/api/ownership/accounts/'+encodeURIComponent(card)+'/assign',{
        method:'POST',credentials:'same-origin',cache:'no-store',signal:controller.signal,
        headers:{'Content-Type':'application/json','X-CSRF-TOKEN':csrf.requestToken},
        body:JSON.stringify({ownerId:owner})
      });
      if(active.current!==controller||controller.signal.aborted)return;
      if(response.status===401||response.status===403){setChoices(null);setState('denied');return;}
      if(response.status===409){setMessage('تعذر الإسناد: تغيرت الملكية أو أهلية الوكيل. تم طلب تحديث القائمة.');}
      else if(response.ok){
        const data:unknown=await response.json();
        if(!exact(data,['username','ownerId','assigned','labOnly'])||data.username!==card
          ||data.ownerId!==owner||data.assigned!==true||data.labOnly!==true)throw new Error('invalid');
        setMessage('تم إسناد الكرت بنجاح.');
      }else setMessage('لم يعتمد الخادم الإسناد. تحقق من القائمة قبل المحاولة مجددا.');
      setRefresh(n=>n+1);
    }catch{
      if(active.current===controller){
        setMessage(sent?'نتيجة الطلب غير مؤكدة. تحقق من القائمة؛ لن يعاد إرسال الإسناد تلقائيا.':'تعذر الحصول على حماية الجلسة.');
        setRefresh(n=>n+1);
      }
    }finally{
      clearTimeout(timeout);
      submitting.current=false;
      if(active.current===controller)setBusy(false);
    }
  }
  if(state==='denied')return null;
  return <><section className="surface-card ownership-panel" data-ownership-state={state} aria-labelledby="ownershipTitle">
    <h2 id="ownershipTitle">إسناد ملكية كروت المختبر</h2>
    <p className="section-note">للمسؤول الأعلى فقط. الإسناد الأول للكروت النشطة غير المنسوبة. لن يتم تغيير الملكية الحالية من هذا القسم.</p>
    {state==='loading'?<p role="status">جار قراءة الكروت والوكلاء...</p>:state==='error'?
      <p role="alert">تعذر قراءة الخيارات الموثقة. أعد تحديث القائمة.</p>:choices&&
      <form onSubmit={event=>{void submit(event);}}>
        <div className="ownership-fields">
          <label>الكرت غير المنسوب<select id="ownershipCard" value={card} disabled={busy} onChange={e=>setCard(e.target.value)}>
            <option value="">اختر الكرت</option>
            {choices.accounts.map(x=><option key={x.username} value={x.username}>{x.username} — {x.planName}</option>)}
          </select></label>
          <label>الوكيل المؤهل<select id="ownershipReseller" value={owner} disabled={busy} onChange={e=>setOwner(e.target.value)}>
            <option value="">اختر الوكيل</option>
            {choices.resellers.map(x=><option key={x.id} value={x.id}>{x.username??x.id}</option>)}
          </select></label>
        </div>
        {choices.limited&&<p className="section-note">توجد نتائج إضافية خارج أول 100 عنصر. لا تعرض هذه القائمة جميع السجلات.</p>}
        {!choices.accounts.length&&<p className="section-note">لا توجد كروت نشطة غير منسوبة في القائمة الحالية.</p>}
        <button id="ownershipAssign" className="btn primary" type="submit" disabled={busy||!card||!owner}>{busy?'جار الإسناد...':'إسناد الكرت'}</button>
      </form>}
    <div className="ownership-actions"><button className="btn subtle" type="button" disabled={busy||state==='loading'} onClick={()=>setRefresh(n=>n+1)}>تحديث الخيارات</button>
      <span role="status" data-ownership-result>{message}</span></div>
  </section>
  {state==='ready'&&choices&&<TransferForm resellers={choices.resellers} limited={choices.limited}/>}
  </>;
}

type TransferRow={id:string;previousOwnerId:string;newOwnerId:string;actorId:string;occurredAt:string};
type OwnershipSnapshot={username:string;active:boolean;ownerId:string|null;version:string|null;transfers:TransferRow[];hasMore:boolean};
const uuid=(x:unknown):x is string=>typeof x==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(x)&&x!=='00000000-0000-0000-0000-000000000000';
const utc=(x:unknown):x is string=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|\+00:00)$/.test(x)&&Number.isFinite(Date.parse(x));
function parseHistory(value:unknown,username:string):OwnershipSnapshot|null{
  if(!exact(value,['username','active','ownerId','version','transfers','hasMore','limit','labOnly'])
    ||value.username!==username||value.labOnly!==true||value.limit!==50||typeof value.active!=='boolean'
    ||!(value.ownerId===null&&value.version===null||ownerId(value.ownerId)&&uuid(value.version))
    ||!Array.isArray(value.transfers)||value.transfers.length>50||typeof value.hasMore!=='boolean'
    ||(value.hasMore&&value.transfers.length!==50))return null;
  const transfers:TransferRow[]=[];const ids=new Set<string>();
  for(const row of value.transfers){
    if(!exact(row,['id','previousOwnerId','newOwnerId','actorId','occurredAt'])
      ||!uuid(row.id)||ids.has(row.id)||!ownerId(row.previousOwnerId)||!ownerId(row.newOwnerId)
      ||row.previousOwnerId===row.newOwnerId||!ownerId(row.actorId)||!utc(row.occurredAt))return null;
    ids.add(row.id);
    transfers.push({id:row.id,previousOwnerId:row.previousOwnerId,newOwnerId:row.newOwnerId,actorId:row.actorId,occurredAt:row.occurredAt});
  }
  return {username,active:value.active,ownerId:value.ownerId as string|null,version:value.version as string|null,transfers,hasMore:value.hasMore};
}

function TransferForm({resellers,limited}:{resellers:Reseller[];limited:boolean}){
  const [card,setCard]=useState('');
  const [snapshot,setSnapshot]=useState<OwnershipSnapshot|null>(null);
  const [target,setTarget]=useState('');
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState('');
  const [denied,setDenied]=useState(false);
  const request=useRef<AbortController|null>(null);
  useEffect(()=>()=>{request.current?.abort();request.current=null;},[]);
  const name=(id:string)=>resellers.find(r=>r.id===id)?.username??id;
  const targets=resellers.filter(r=>r.id!==snapshot?.ownerId);
  function clear(){
    request.current?.abort();request.current=null;
    setSnapshot(null);setTarget('');setBusy(false);setMessage('');
  }
  async function read(username:string,notice=''){
    if(!labName(username))return;
    request.current?.abort();
    const c=new AbortController();request.current=c;
    setBusy(true);setSnapshot(null);setTarget('');setMessage(notice);
    const timeout=setTimeout(()=>c.abort(),8000);
    try{
      const response=await fetch('/api/ownership/accounts/'+encodeURIComponent(username)+'/history',
        {credentials:'same-origin',cache:'no-store',signal:c.signal});
      if(request.current!==c)return;
      if(response.status===401||response.status===403){setDenied(true);return;}
      if(response.status===404){setMessage('الكرت غير مسجل في المختبر.');return;}
      if(!response.ok)throw new Error('read');
      const value=parseHistory(await response.json(),username);
      if(!value)throw new Error('contract');
      if(request.current===c)setSnapshot(value);
    }catch{
      if(request.current===c)setMessage(notice?notice+' تعذر تحديث الحالة؛ أعد قراءتها.':'تعذر قراءة حالة الملكية الحالية.');
    }finally{
      clearTimeout(timeout);
      if(request.current===c){request.current=null;setBusy(false);}
    }
  }
  async function transfer(event:FormEvent<HTMLFormElement>){
    event.preventDefault();
    if(request.current||busy||!snapshot?.active||!snapshot.ownerId||!snapshot.version
      ||snapshot.username!==card||!targets.some(r=>r.id===target))return;
    const previous=snapshot;
    if(!window.confirm('نقل الكرت '+card+' من '+name(previous.ownerId!)+' إلى '+name(target)+'؟'))return;
    const c=new AbortController();request.current=c;
    setBusy(true);setMessage('');
    const timeout=setTimeout(()=>c.abort(),10000);
    let sent=false;let notice='';
    try{
      const csrf=await readJson('/api/admin/auth/csrf',c.signal);
      if(!isObject(csrf)||typeof csrf.requestToken!=='string'||csrf.requestToken.length<20)throw new Error('csrf');
      sent=true;
      const response=await fetch('/api/ownership/accounts/'+encodeURIComponent(card)+'/transfer',{
        method:'POST',credentials:'same-origin',cache:'no-store',signal:c.signal,
        headers:{'Content-Type':'application/json','X-CSRF-TOKEN':csrf.requestToken},
        body:JSON.stringify({expectedOwnerId:previous.ownerId,expectedVersion:previous.version,newOwnerId:target})
      });
      if(request.current!==c)return;
      if(response.status===401||response.status===403){setDenied(true);setSnapshot(null);return;}
      if(response.status===409)notice='تغيرت الملكية أو أهلية الوكيل؛ تمت إعادة قراءة الحالة دون إعادة إرسال النقل.';
      else if(response.ok){
        const data:unknown=await response.json();
        if(!exact(data,['username','ownerId','version','transferred','labOnly'])||data.username!==card
          ||data.ownerId!==target||!uuid(data.version)||data.version===previous.version||data.transferred!==true||data.labOnly!==true)throw new Error('contract');
        notice='تم نقل الملكية بنجاح.';
      }else notice='لم يعتمد الخادم النقل؛ تحقق من الحالة الحالية.';
    }catch{
      notice=sent?'نتيجة النقل غير مؤكدة؛ تحقق من الحالة. لن يعاد إرسال الطلب تلقائيا.':'تعذر توفير حماية الجلسة.';
    }finally{
      clearTimeout(timeout);
      if(request.current===c){
        request.current=null;
        setBusy(false);
        setSnapshot(null);setTarget('');
        if(notice)void read(previous.username,notice);
      }
    }
  }
  if(denied)return null;
  return <section className="surface-card ownership-panel" aria-labelledby="transferTitle">
    <h2 id="transferTitle">نقل الملكية وسجل الانتقال</h2>
    <p className="section-note">ابحث برقم الكرت المختبري المسجل. النقل يتطلب حالة ملكية حديثة وكرتا نشطا، ولا يغير كلمة المرور أو يفصل الجلسات.</p>
    <form className="ownership-fields" onSubmit={event=>{event.preventDefault();if(!busy)void read(card);}}>
      <label>رقم الكرت<input id="transferCard" dir="ltr" value={card} maxLength={16} disabled={busy}
        onChange={e=>{clear();setCard(e.target.value.trim());}} placeholder="lab_000000000000"/></label>
      <button className="btn subtle" id="transferLookup" type="submit" disabled={busy||!labName(card)}>قراءة الملكية</button>
    </form>
    {busy&&<p role="status">جار التحقق من الخادم...</p>}
    {snapshot&&<div data-transfer-ready={snapshot.username}>
      <p>المالك الحالي: <strong data-transfer-owner={snapshot.ownerId??''}>{snapshot.ownerId?name(snapshot.ownerId):'غير منسوب'}</strong> — {snapshot.active?'نشط':'معطل'}</p>
      {snapshot.active&&snapshot.ownerId&&snapshot.version?<form onSubmit={event=>{void transfer(event);}}>
        <div className="ownership-fields"><label>الوكيل الجديد<select id="transferTarget" value={target} disabled={busy} onChange={e=>setTarget(e.target.value)}>
          <option value="">اختر الوكيل</option>{targets.map(r=><option key={r.id} value={r.id}>{r.username??r.id}</option>)}
        </select></label>
        <button id="transferSubmit" className="btn primary" type="submit" disabled={busy||!target}>نقل الملكية</button></div>
        {limited&&<p className="section-note">اختيار الوكيل محدود بنتائج القائمة الحالية.</p>}
      </form>:<p className="section-note">النقل غير متاح لهذه الحالة.</p>}
      <h3>آخر عمليات النقل المسجلة</h3>
      <p className="section-note">تعرض آخر 50 عملية نقل مسجلة، ولا يشمل السجل إسنادات أو انتقالات سابقة لم تسجل تاريخيا. الأسماء المعروضة حاليا من قائمة الوكلاء، والمعرفات ثابتة.</p>
      {snapshot.hasMore&&<p className="section-note">توجد عمليات أقدم خارج الحد المعروض.</p>}
      {!snapshot.transfers.length?<p>لا توجد عمليات نقل مسجلة.</p>:<div className="ownership-history"><table aria-label="سجل نقل الملكية"><thead><tr><th>المالك السابق</th><th>المالك الجديد</th><th>معرف المسؤول</th><th>التوقيت</th></tr></thead><tbody>
        {snapshot.transfers.map(t=><tr key={t.id} data-transfer-event={t.id}><td>{name(t.previousOwnerId)}</td><td>{name(t.newOwnerId)}</td><td dir="ltr">{t.actorId}</td><td>{new Date(t.occurredAt).toLocaleString('ar')}</td></tr>)}
      </tbody></table></div>}
    </div>}
    <p role="status" data-transfer-result>{message}</p>
  </section>;
}
