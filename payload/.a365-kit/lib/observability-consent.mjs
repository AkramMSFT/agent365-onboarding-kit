import { stripVTControlCharacters } from 'node:util';

export const ADMIN_ACTION_EXIT_CODE = 2;
export const OBSERVABILITY_CONSENT_MESSAGE =
  'Custom permission configuration requires tenant admin action.\n' +
  'An administrator must grant the blueprint consent for maven-prod [Agent365.Observability.OtelWrite] via the Entra portal.';

const detail = OBSERVABILITY_CONSENT_MESSAGE.split('\n')[1].toLowerCase();
const maximumRetainedCharacters = 16_384;

export function createConsentDetector() {
  let recent = '';
  let pending = false;
  return {
    accept(text) {
      if (pending) return;
      const combined = recent + text;
      const normalized = stripVTControlCharacters(combined).replace(/\s+/gu, ' ').toLowerCase();
      // The resource-specific sentence is sufficient if the generic heading is on another stream.
      pending = normalized.includes(detail);
      recent = pending ? '' : combined.slice(-maximumRetainedCharacters);
    },
    get pending() { return pending; }
  };
}

export function observabilityConsentGuidance() {
  return [
    '[Agent 365 kit] Observability consent is pending administrator action.',
    'In https://entra.microsoft.com, open ID Governance > Entitlement management > Access packages.',
    '1. Create an access package (or have an administrator verify a suitable existing one). Add this resource role:',
    '   Resource: maven-prod',
    '   Type: OAuthApplication',
    '   Sub Type: API',
    '   Role: Agent365.Observability.OtelWrite',
    '2. Create an initial policy that permits assigning the intended blueprint, following tenant approval and lifecycle requirements.',
    '3. Assign the access package under that policy to the blueprint identified by this setup.',
    '   Confirm agentBlueprintId in a365.generated.config.json; do not assign it to the interactive CLI client or human operator.',
    '4. Wait for the blueprint access-package assignment status to become "Delivered".',
    '   Creating the policy or seeing Approved/Delivering is not delivery. Timing varies; inspect Requests/Assignments if delivery stalls.',
    '5. Only after Delivered, resume the affected setup step and verify effective permissions and telemetry ingestion.',
    'If maven-prod or the role is unavailable, contact the tenant/catalog administrator; do not invent resource IDs or bypass consent.',
    'This runner does not create the package, grant permissions, poll delivery, or mark setup complete.',
    'Guide: .a365-kit/shared/observability-access-package.md'
  ].join('\n') + '\n';
}
