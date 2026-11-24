import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { StatusPanel } from './StatusPanel';
import { OverviewKpis, OverviewRecent, OverviewPackages, OverviewServices } from './Overview';
import { SessionLogin } from './SessionLogin';
import { PlanEditor, PlansTable } from './PlanManagement';
import { VoucherList } from './VoucherList';
import { VoucherCreator } from './VoucherCreator';
import { SessionTable } from './SessionTable';
import { UsageReport } from './UsageReport';
import { CapacityCalculator } from './CapacityCalculator';
import { LiveStatusPanel } from './LiveStatusPanel';
import { ServiceHistoryPanel } from './ServiceHistoryPanel';
import { ServiceAlertsPanel } from './ServiceAlertsPanel';
import { OwnershipPanel } from './OwnershipPanel';
import { ResellerWorkspace } from './ResellerWorkspace';

// Incremental migration: the original JavaScript dashboard still owns all
// existing forms, routes, RADIUS workflows and operator interactions.
const mount = document.getElementById('reactNocStatus');
if (mount) {
  createRoot(mount).render(
    <StrictMode><StatusPanel /></StrictMode>,
  );
}

const loginMount = document.getElementById('reactAdminLogin');
if (loginMount) {
  createRoot(loginMount).render(<StrictMode><SessionLogin /></StrictMode>);
}

const overviewKpiMount = document.getElementById('reactOverviewKpis');
if (overviewKpiMount) {
  createRoot(overviewKpiMount).render(<StrictMode><OverviewKpis /></StrictMode>);
}

const overviewRecentMount = document.getElementById('reactOverviewRecent');
if (overviewRecentMount) {
  createRoot(overviewRecentMount).render(<StrictMode><OverviewRecent /></StrictMode>);
}

const overviewPackagesMount = document.getElementById('reactOverviewPackages');
if (overviewPackagesMount) {
  createRoot(overviewPackagesMount).render(<StrictMode><OverviewPackages /></StrictMode>);
}

const overviewServicesMount = document.getElementById('reactOverviewServices');
if (overviewServicesMount) {
  createRoot(overviewServicesMount).render(<StrictMode><OverviewServices /></StrictMode>);
}

const planEditorMount = document.getElementById('reactPlanEditor');
if (planEditorMount) {
  createRoot(planEditorMount).render(<StrictMode><PlanEditor /></StrictMode>);
}
const plansTableMount = document.getElementById('reactPlansTable');
if (plansTableMount) {
  createRoot(plansTableMount).render(<StrictMode><PlansTable /></StrictMode>);
}

const vouchersMount = document.getElementById('reactVoucherList');
if (vouchersMount) {
  createRoot(vouchersMount).render(<StrictMode><VoucherList /></StrictMode>);
}

const voucherCreatorMount = document.getElementById('reactVoucherCreator');
if (voucherCreatorMount) {
  createRoot(voucherCreatorMount).render(<StrictMode><VoucherCreator /></StrictMode>);
}

const sessionsMount = document.getElementById('reactSessionTable');
if (sessionsMount) {
  createRoot(sessionsMount).render(<StrictMode><SessionTable /></StrictMode>);
}

const usageReportMount = document.getElementById('reactUsageReport');
if (usageReportMount) {
  createRoot(usageReportMount).render(<StrictMode><UsageReport /></StrictMode>);
}

const capacityMount = document.getElementById('reactCapacityCalculator');
if (capacityMount) {
  createRoot(capacityMount).render(<StrictMode><CapacityCalculator /></StrictMode>);
}

const liveStatusMount = document.getElementById('reactLiveStatus');
if (liveStatusMount) {
  createRoot(liveStatusMount).render(<StrictMode><LiveStatusPanel /></StrictMode>);
}

const serviceHistoryMount = document.getElementById('reactServiceHistory');
if (serviceHistoryMount) {
  createRoot(serviceHistoryMount).render(<StrictMode><ServiceHistoryPanel /></StrictMode>);
}

const serviceAlertsMount = document.getElementById('reactServiceAlerts');
if (serviceAlertsMount) {
  createRoot(serviceAlertsMount).render(<StrictMode><ServiceAlertsPanel /></StrictMode>);
}

const ownershipMount = document.getElementById('reactOwnership');
if (ownershipMount) {
  createRoot(ownershipMount).render(<StrictMode><OwnershipPanel /></StrictMode>);
}

const resellerMount = document.getElementById('reactResellerWorkspace');
if (resellerMount) {
  createRoot(resellerMount).render(<StrictMode><ResellerWorkspace /></StrictMode>);
}
