// A generation token ensures that an earlier asynchronous voucher response
// cannot reveal credentials after logout, navigation or a newer request.
export function createOneTimeRevealGate() {
  let generation = 0;
  return {
    begin() { generation += 1; return generation; },
    invalidate() { generation += 1; },
    isCurrent(token) { return Number.isSafeInteger(token) && token === generation; },
  };
}
