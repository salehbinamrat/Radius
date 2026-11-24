// Same lab-only eligibility as the original selector, but without passing raw
// plan records or optional confidential fields into the React component.
export function eligibleVoucherPlans(plans) {
  return (Array.isArray(plans) ? plans : []).filter(plan =>
    plan.active === true && plan.quotaBytes === null && plan.validityDays === null &&
    typeof plan.id === 'string' && plan.id.length > 0 &&
    typeof plan.name === 'string' && plan.name.length > 0)
    .map(plan => ({ id: plan.id, name: plan.name }));
}
