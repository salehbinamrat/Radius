/** Single in-flight dashboard read per session; never cache completed data. */
export function createRefreshCoordinator(timeoutMs = 8000) {
  let active = null;
  function invalidate() {
    const previous = active;
    active = null;
    previous?.controller.abort();
  }
  function run(task, { fresh = false } = {}) {
    if (active && !fresh) return active.promise;
    if (active) invalidate();
    const controller = new AbortController();
    const entry = { controller, promise: null };
    active = entry;
    const isCurrent = () => active === entry;
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    entry.promise = Promise.resolve().then(() => {
      if (!isCurrent()) throw new DOMException('Refresh superseded', 'AbortError');
      return task({ signal: controller.signal, isCurrent });
    }).finally(() => {
      clearTimeout(timer);
      // Abort any sibling fetches if one of the three reads failed.
      controller.abort();
      if (isCurrent()) active = null;
    });
    return entry.promise;
  }
  return { run, invalidate };
}
