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
  return <section className="surface-card ownership-panel" data-ownership-state={state} aria-labelledby="ownershipTitle">
    <h2 id="ownershipTitle">إسناد ملكية كروت المختبر</h2>
    <p className="section-note">للمسؤول الأعلى فقط. الإسناد الأول للكروت النشطة غير المنسوبة، دون نقل أو حذف ملكية.</p>
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
  </section>;
}
