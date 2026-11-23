import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { StatusPanel } from './StatusPanel';

// Incremental migration: the original JavaScript dashboard still owns all
// existing forms, routes, RADIUS workflows and operator interactions.
const mount = document.getElementById('reactNocStatus');
if (mount) {
  createRoot(mount).render(
    <StrictMode><StatusPanel /></StrictMode>,
  );
}
