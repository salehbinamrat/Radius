import { useEffect, useState } from 'react';

type Health = 'loading' | 'online' | 'offline';

/** First React/TypeScript NOC component: public read-only local health signal. */
export function StatusPanel() {
  const [health, setHealth] = useState<Health>('loading');
  useEffect(() => {
    const controller = new AbortController();
    async function probe() {
      try {
        const response = await fetch('/api/health/live', {
          signal: controller.signal, cache: 'no-store', credentials: 'omit',
        });
        if (!controller.signal.aborted) setHealth(response.ok ? 'online' : 'offline');
      } catch {
        if (!controller.signal.aborted) setHealth('offline');
      }
    }
    void probe();
    return () => controller.abort();
  }, []);
  const label = health === 'online'
    ? 'واجهة React/TypeScript: الخادم يعمل'
    : health === 'offline'
      ? 'واجهة React/TypeScript: تعذر الوصول إلى الخادم'
      : 'واجهة React/TypeScript: جار التحقق من الخادم';
  return <span role="status" aria-live="polite" data-noc-stack="react-typescript" data-health={health}>{label}</span>;
}
