import { buildSafeCsv } from './noc-utils.mjs';
import { buildSessionViewSnapshot, filterLoadedSessions } from './session-view-model.mjs';

/** Read-only laboratory accounting + purely hypothetical capacity planning. */
export function initializeUltraFeatures({ request, notify, record }) {
  const el = id => document.getElementById(id);
  let sessions = [];
  let sessionHealth = 'unloaded';
  let activeFetch = null;
  function text(id, value) { el(id).textContent = String(value); }
  function time(value) {
    if (!value) return '—';
    const date=new Date(value);
    return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString('ar', {dateStyle:'short',timeStyle:'short'});
  }
  const labels={closed:'مغلقة',stale:'قديمة / غير مؤكدة','open-unconfirmed':'مفتوحة (غير مؤكدة)',anomaly:'بيانات غير سليمة'};
  function draw() {
    // The authorized API and export data stay in this controller. Only
    // allowlisted, formatted, first-100-loaded display fields enter React.
    const snapshot = buildSessionViewSnapshot(sessions, el('ultraSessionSearch').value);
    text('ultraSessionCount',`المعروض ${snapshot.visibleCount} من ${snapshot.loadedCount} سجل محمل`);
    window.dispatchEvent(new CustomEvent('radius-sessions-updated', {
      detail: { snapshot, health: sessionHealth },
    }));
  }
  window.addEventListener('radius-sessions-request', draw);
  async function refresh() {
    const button=el('ultraSessionsRefresh');button.disabled=true;
    text('ultraSessionsWarning','جار قراءة سجلات المحاسبة من الخادم...');
    const seq=Symbol('request');activeFetch=seq;
    try{
      const state=el('ultraSessionState').value;
      const response=await request(`/api/lab-sessions?state=${encodeURIComponent(state)}`);
      if(activeFetch!==seq) return;
      sessions=Array.isArray(response.sessions)?response.sessions:[];
      sessionHealth='online';draw();
      text('ultraSessionUpdated',time(response.observedAt));
      text('ultraSessionsWarning',response.warning+(response.hasMore?' عُرض أول 100 سجل فقط؛ لا تُعد النتائج جميع الجلسات.':''));
      record(`مراجعة ${sessions.length} سجل محاسبة للمختبر`);
    } catch(error){
      if(activeFetch!==seq) return;
      sessions=[];sessionHealth='error';draw();text('ultraSessionsWarning',`تعذر تحديث سجلات المحاسبة: ${error.message}`);
      notify(error.message,'error');
    } finally {if(activeFetch===seq)button.disabled=false;}
  }
  el('ultraSessionsRefresh').addEventListener('click',refresh);
  el('ultraSessionState').addEventListener('change',refresh);
  el('ultraSessionSearch').addEventListener('input',draw);
  el('ultraSessionsExport').addEventListener('click',()=>{
    const rows=filterLoadedSessions(sessions, el('ultraSessionSearch').value)
      .map(s=>[s.username,s.framedIp,s.callingStationId,s.nasIp,labels[s.classification]||'غير معروف',s.startedAt||'',s.updatedAt||'',s.uploadBytes??'',s.downloadBytes??'',s.terminateCause]);
    if(!rows.length){notify('لا توجد سجلات محملة للتصدير.','error');return;}
    const csv=buildSafeCsv(['الكرت','IP','MAC','NAS','حالة السجل','البداية','آخر تحديث','رفع بايت','تنزيل بايت','سبب الإنهاء'],rows);
    const url=URL.createObjectURL(new Blob([csv],{type:'text/csv;charset=utf-8'}));
    const link=document.createElement('a');link.href=url;link.download='radius-lab-sessions-visible.csv';document.body.append(link);link.click();link.remove();
    URL.revokeObjectURL(url);
    record(`تصدير ${rows.length} سجل محاسبة تجريبي`);notify(`تم تصدير ${rows.length} سجل من النتائج المعروضة فقط.`,'success');
  });
  return {
    refresh,
    reset(){activeFetch=null;el('ultraSessionsRefresh').disabled=false;sessions=[];sessionHealth='unloaded';draw();text('ultraSessionUpdated','لم يتم الاستعلام');
      text('ultraSessionsWarning','سجلات المحاسبة لم تُحمّل بعد. افتح القسم واختر تحديث للعرض.');}
  };
}
