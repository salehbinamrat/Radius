import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { StatusPanel } from './StatusPanel';
import { OverviewKpis, OverviewRecent, OverviewPackages, OverviewServices } from './Overview';
import { SessionLogin } from './SessionLogin';

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
