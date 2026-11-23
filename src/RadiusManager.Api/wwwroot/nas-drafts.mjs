/** Draft NAS metadata only. This module cannot contact routers or configure FreeRADIUS. */
export function initializeNasDrafts({request, notify, record}) {
  const el = id => document.getElementById(id);
  let items = [];
  let inFlight = false;
  function draw() {
    const body = el('nasDraftList');body.replaceChildren();
    el('nasDraftCount').textContent = `المعروض ${items.length} مسودة (حد القراءة: 100)`;
    if (!items.length) {
      const row=body.insertRow();const cell=row.insertCell();cell.colSpan=5;
      cell.textContent='لا توجد مسودات محفوظة في قاعدة البيانات.';return;
    }
    for(const item of items) {
      const row=body.insertRow();
      for(const value of [item.name,item.site,item.vpnIp,item.retired?'مغلقة':'مسودة غير مفعلة'])
        row.insertCell().textContent=String(value??'');
      const actions=row.insertCell();
      if(item.retired){actions.textContent='—';continue;}
      const btn=document.createElement('button');btn.type='button';btn.className='btn subtle';
      btn.textContent='إغلاق المسودة';
      btn.addEventListener('click',async()=>{
        if(!window.confirm('إغلاق المسودة فقط؟ لن يتم تعديل جهاز MikroTik أو خادم FreeRADIUS.'))return;
        btn.disabled=true;
        try{
          await request(`/api/nas-drafts/${encodeURIComponent(item.id)}/retire`,{method:'POST'});
          record(`إغلاق مسودة NAS: ${item.name}`);notify('تم إغلاق المسودة دون تغيير الأجهزة.','success');
          await refresh();
        }catch(error){notify(error.message,'error');btn.disabled=false;}
      });actions.append(btn);
    }
  }
  async function refresh() {
    if(inFlight)return;
    inFlight=true;el('nasDraftRefresh').disabled=true;el('nasDraftError').textContent='';
    try{
      const data=await request('/api/nas-drafts');
      items=Array.isArray(data.drafts)?data.drafts:[];draw();
      el('nasDraftMessage').textContent=data.warning||'الراوترات ليست متصلة فعليا.';
    }catch(error){items=[];draw();el('nasDraftError').textContent=error.message;}
    finally{inFlight=false;el('nasDraftRefresh').disabled=false;}
  }
  el('nasDraftRefresh').addEventListener('click',refresh);
  el('nasDraftForm').addEventListener('submit',async event=>{
    event.preventDefault();const form=el('nasDraftForm');if(!form.reportValidity())return;
    const button=el('nasDraftSave');button.disabled=true;el('nasDraftError').textContent='';
    try{
      await request('/api/nas-drafts',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({name:el('nasDraftName').value.trim(),site:el('nasDraftSite').value.trim(),vpnIp:el('nasDraftIp').value.trim()})});
      form.reset();record('حفظ مسودة راوتر تجريبي');notify('حُفظت المسودة دون ربط الراوتر.','success');
      await refresh();
    }catch(error){el('nasDraftError').textContent=error.message;}
    finally{button.disabled=false;}
  });
  draw();
  return {refresh,reset(){items=[];draw();el('nasDraftMessage').textContent='لم يتم الاستعلام بعد.';el('nasDraftError').textContent='';}};
}
