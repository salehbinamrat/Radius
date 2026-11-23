import { normalizedPlan } from './plan-utils.mjs';
const el = id => document.getElementById(id);
let auth = '';
let editingId = null;
let plans = [];
const header = () => ({ Authorization: `Basic ${auth}` });
async function call(url, options={}) {
  const response = await fetch(url,{ ...options,headers:{...header(),...(options.headers||{})},cache:'no-store'});
  let body;
  try { body=await response.json(); } catch { body={}; }
  if (!response.ok) throw new Error(body.error || `خطأ HTTP ${response.status}`);
  return body;
}
async function reload(){
 const [summary, all, accounts] = await Promise.all([call('/api/summary'),call('/api/plans'),call('/api/lab-accounts')]);
 el('statPlans').textContent=summary.plans.toLocaleString('en-US');
 el('statUsers').textContent=summary.labAccounts.toLocaleString('en-US');
 plans=all;
 const select=el('labPlan');select.replaceChildren();
 for(const p of plans.filter(x=>x.active && x.quotaBytes===null && x.validityDays===null)) {
   const opt=document.createElement('option');opt.value=p.id;opt.textContent=p.name;select.append(opt);
 }
 const labs=el('labList');labs.replaceChildren();
 for(const a of accounts){
   const tr=labs.insertRow();
   tr.insertCell().textContent=a.username;
   tr.insertCell().textContent=a.planName;
   tr.insertCell().textContent=a.active?'نشط (مختبر)':'موقوف';
   const td=tr.insertCell();
   if(a.active){
     const btn=document.createElement('button');btn.type='button';btn.textContent='تعطيل';
     btn.addEventListener('click',async()=>{
       el('labError').textContent='';
       try{await call(`/api/lab-accounts/${encodeURIComponent(a.username)}/disable`,{method:'POST'});await reload();}
       catch(e){el('labError').textContent=e.message;}
     });td.append(btn);
   }
 }
 const body=el('plansList');body.replaceChildren();
 if (!plans.length){const row=body.insertRow();const cell=row.insertCell();cell.colSpan=5;cell.textContent='لا توجد باقات بعد.';return;}
 for(const p of plans){
  const row=body.insertRow();
  for(const v of [p.name,`${p.downloadKbps}k`,`${p.uploadKbps}k`,p.active?'تجريبية':'موقوفة'])row.insertCell().textContent=v;
  const actions=row.insertCell();const b=document.createElement('button');b.type='button';b.textContent='تعديل';b.className='secondary';b.addEventListener('click',()=>editPlan(p));actions.appendChild(b);
 }
}
function editPlan(p){
 editingId=p.id;
 el('planFormTitle').textContent='تعديل الباقة: '+p.name;
 el('planName').value=p.name;el('planDown').value=p.downloadKbps;el('planUp').value=p.uploadKbps;
 el('planQuota').value=p.quotaBytes===null?'':String(Math.floor(p.quotaBytes/(1024*1024)));
 el('planDays').value=p.validityDays??'';
 el('savePlan').textContent='حفظ التعديل';el('cancelEdit').hidden=false;
 window.scrollTo({top:0,behavior:'smooth'});
}
function clearEdit(){editingId=null;el('planFormTitle').textContent='إنشاء باقة تجريبية';el('planForm').reset();el('savePlan').textContent='حفظ الباقة';el('cancelEdit').hidden=true;}
el('loginForm').addEventListener('submit', async ev=>{
 ev.preventDefault();el('loginError').textContent='';
 auth=btoa(`${el('loginUser').value}:${el('loginPass').value}`);
 try{await reload();el('loginPanel').hidden=true;el('dashboard').hidden=false;el('loginPass').value='';}
 catch(err){auth='';el('loginError').textContent=err.message;}
});
el('logout').addEventListener('click',()=>{auth='';plans=[];el('labCredentials').textContent='';el('labCredentials').hidden=true;clearEdit();el('dashboard').hidden=true;el('loginPanel').hidden=false;});
el('refresh').addEventListener('click',()=>reload().catch(err=>{el('planError').textContent=err.message;}));
el('cancelEdit').addEventListener('click',clearEdit);
el('labForm').addEventListener('submit',async e=>{
 e.preventDefault();el('labError').textContent='';el('labCredentials').hidden=true;
 try {
  const data=await call('/api/lab-accounts',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({planId:el('labPlan').value})});
  el('labCredentials').textContent=`رقم الكرت: ${data.username}\nكلمة المرور (تظهر مرة واحدة): ${data.password}`;
  el('labCredentials').hidden=false;
  await reload();
 } catch(err){el('labError').textContent=err.message;}
});
el('planForm').addEventListener('submit',async ev=>{
 ev.preventDefault();el('planError').textContent='';
 try{
  const data=normalizedPlan(el('planName').value,el('planDown').value,el('planUp').value,el('planQuota').value,el('planDays').value);
  await call(editingId?`/api/plans/${editingId}`:'/api/plans',{method:editingId?'PUT':'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});
  clearEdit();await reload();
 }catch(err){el('planError').textContent=err.message;}
});
