import { buildSafeCsv } from './noc-utils.mjs';
import { estimateCapacity } from './capacity-utils.mjs';

/** Read-only laboratory accounting + purely hypothetical capacity planning. */
export function initializeUltraFeatures({ request, notify, record }) {
  const el = id => document.getElementById(id);
  let sessions = [];
  let activeFetch = null;
  function text(id, value) { el(id).textContent = String(value); }
  function time(value) {
    if (!value) return '—';
    const date=new Date(value);
    return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString('ar', {dateStyle:'short',timeStyle:'short'});
  }
  function bytes(value) {
    if (value === null || value === undefined || !Number.isFinite(Number(value)) || Number(value)<0) return 'غير سليم';
    const size=Number(value), mb=size/1048576;
    return mb>=1024 ? `${(mb/1024).toFixed(2)} GB` : `${mb.toFixed(2)} MB`;
  }
  const labels={closed:'مغلقة',stale:'قديمة / غير مؤكدة','open-unconfirmed':'مفتوحة (غير مؤكدة)',anomaly:'بيانات غير سليمة'};
  function draw() {
    const body=el('ultraSessionsList');body.replaceChildren();
    const q=el('ultraSessionSearch').value.trim().toLowerCase();
    const filtered=sessions.filter(s=>`${s.username} ${s.framedIp} ${s.callingStationId} ${s.nasIp}`.toLowerCase().includes(q));
    for(const s of filtered) {
      const row=body.insertRow();
      const cells=[s.username,s.framedIp||'—',s.callingStationId||'—',s.nasIp||'—',labels[s.classification]||'غير معروف',
        time(s.startedAt),time(s.updatedAt),`${bytes(s.uploadBytes)} / ${bytes(s.downloadBytes)}`,s.terminateCause||'—'];
      for(const value of cells){const c=row.insertCell();c.textContent=value;}
      row.dataset.state=s.classification;
    }
    if(!filtered.length){const row=body.insertRow();const c=row.insertCell();c.colSpan=9;c.textContent='لا توجد سجلات مطابقة في النتائج المحملة.';}
    text('ultraSessionCount',`المعروض ${filtered.length} من ${sessions.length} سجل محمل`);
  }
  async function refresh() {
    const button=el('ultraSessionsRefresh');button.disabled=true;
    text('ultraSessionsWarning','جار قراءة سجلات المحاسبة من الخادم...');
    const seq=Symbol('request');activeFetch=seq;
    try{
      const state=el('ultraSessionState').value;
      const response=await request(`/api/lab-sessions?state=${encodeURIComponent(state)}`);
      if(activeFetch!==seq) return;
      sessions=Array.isArray(response.sessions)?response.sessions:[];
      draw();
      text('ultraSessionUpdated',time(response.observedAt));
      text('ultraSessionsWarning',response.warning+(response.hasMore?' عُرض أول 100 سجل فقط؛ لا تُعد النتائج جميع الجلسات.':''));
      record(`مراجعة ${sessions.length} سجل محاسبة للمختبر`);
    } catch(error){
      if(activeFetch!==seq) return;
      sessions=[];draw();text('ultraSessionsWarning',`تعذر تحديث سجلات المحاسبة: ${error.message}`);
      notify(error.message,'error');
    } finally {if(activeFetch===seq)button.disabled=false;}
  }
  el('ultraSessionsRefresh').addEventListener('click',refresh);
  el('ultraSessionState').addEventListener('change',refresh);
  el('ultraSessionSearch').addEventListener('input',draw);
  el('ultraSessionsExport').addEventListener('click',()=>{
    const q=el('ultraSessionSearch').value.trim().toLowerCase();
    const rows=sessions.filter(s=>`${s.username} ${s.framedIp} ${s.callingStationId} ${s.nasIp}`.toLowerCase().includes(q))
      .map(s=>[s.username,s.framedIp,s.callingStationId,s.nasIp,labels[s.classification]||'غير معروف',s.startedAt||'',s.updatedAt||'',s.uploadBytes??'',s.downloadBytes??'',s.terminateCause]);
    if(!rows.length){notify('لا توجد سجلات محملة للتصدير.','error');return;}
    const csv=buildSafeCsv(['الكرت','IP','MAC','NAS','حالة السجل','البداية','آخر تحديث','رفع بايت','تنزيل بايت','سبب الإنهاء'],rows);
    const url=URL.createObjectURL(new Blob([csv],{type:'text/csv;charset=utf-8'}));
    const link=document.createElement('a');link.href=url;link.download='radius-lab-sessions-visible.csv';document.body.append(link);link.click();link.remove();
    URL.revokeObjectURL(url);
    record(`تصدير ${rows.length} سجل محاسبة تجريبي`);notify(`تم تصدير ${rows.length} سجل من النتائج المعروضة فقط.`,'success');
  });
  function calculate(event){
    event?.preventDefault();
    const data={users:Number(el('capUsers').value),averageMbps:Number(el('capSpeed').value),
      peakConcurrencyPercent:Number(el('capConcurrency').value),contentionRatio:Number(el('capSharing').value),
      dailyPeakEquivalentHours:Number(el('capHours').value)};
    try{
      const result=estimateCapacity(data);
      text('capPeakOut',result.peakUsers.toLocaleString('en-US'));
      text('capSpeedOut',`${result.upstreamMbps.toLocaleString('en-US')} Mbps`);
      text('capVolumeOut',`${result.monthlyDecimalTb.toLocaleString('en-US')} TB`);
      text('capError','');el('capResults').hidden=false;
    }catch(error){text('capError',error.message);el('capResults').hidden=true;}
  }
  el('capForm').addEventListener('submit',calculate);
  for(const x of el('capForm').querySelectorAll('input'))x.addEventListener('input',calculate);
  calculate();
  return {
    refresh,
    reset(){activeFetch=null;el('ultraSessionsRefresh').disabled=false;sessions=[];draw();text('ultraSessionUpdated','لم يتم الاستعلام');
      text('ultraSessionsWarning','سجلات المحاسبة لم تُحمّل بعد. افتح القسم واختر تحديث للعرض.');}
  };
}
