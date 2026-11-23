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
 const [summary, all] = await Promise.all([call('/api/summary'),call('/api/plans')]);
 el('statPlans').textContent=summary.plans.toLocaleString('en-US');
 el('statUsers').textContent=summary.labAccounts.toLocaleString('en-US');
 plans=all;
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
el('logout').addEventListener('click',()=>{auth='';plans=[];clearEdit();el('dashboard').hidden=true;el('loginPanel').hidden=false;});
el('refresh').addEventListener('click',()=>reload().catch(err=>{el('planError').textContent=err.message;}));
el('cancelEdit').addEventListener('click',clearEdit);
el('planForm').addEventListener('submit',async ev=>{
 ev.preventDefault();el('planError').textContent='';
 try{
  const data=normalizedPlan(el('planName').value,el('planDown').value,el('planUp').value,el('planQuota').value,el('planDays').value);
  await call(editingId?`/api/plans/${editingId}`:'/api/plans',{method:editingId?'PUT':'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});
  clearEdit();await reload();
 }catch(err){el('planError').textContent=err.message;}
});
