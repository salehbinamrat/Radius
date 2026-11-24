import { useEffect, useState } from 'react';

export type MonitorState<T> = {status:'loading'|'ready'|'error'|'denied';data:T|null};

/** HTTPS session-scoped reads; no shared credentials or persistent browser state. */
export function useServiceMonitor<T>(endpoint:string,parse:(value:unknown)=>T|null) {
  const [enabled,setEnabled]=useState(false);
  const [view,setView]=useState<MonitorState<T>>({status:'loading',data:null});
  useEffect(()=>{
    const scope=(event:Event)=>{
      const active=(event as CustomEvent<{enabled?:boolean}>).detail?.enabled===true && location.protocol==='https:';
      setEnabled(active);
      if (!active) setView({status:'loading',data:null});
    };
    const logout=()=>{setEnabled(false);setView({status:'loading',data:null});};
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
        const response=await fetch(endpoint,{credentials:'same-origin',cache:'no-store',signal:controller.signal});
        if (disposed) return;
        if (response.status===401||response.status===403) {
          denied=true;setView({status:'denied',data:null});return;
        }
        if (!response.ok) throw new Error('history');
        const data=parse(await response.json());
        if (!data) throw new Error('history');
        if (!disposed) setView({status:'ready',data});
      } catch {
        if (!disposed) setView({status:'error',data:null});
      } finally {
        clearTimeout(timeout);
        if (!disposed&&!denied) timer=setTimeout(()=>{void read();},15000);
      }
    }
    setView({status:'loading',data:null});void read();
    return ()=>{disposed=true;clearTimeout(timer);controller?.abort();};
  },[enabled,endpoint,parse]);
  return {enabled,view};
}
