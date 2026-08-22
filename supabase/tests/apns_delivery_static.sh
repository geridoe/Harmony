#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/202608220066_apns_delivery_worker.sql"
worker="$root/supabase/functions/apns-delivery-worker/index.ts"
env_example="$root/supabase/functions/.env.example"

test -f "$migration"
test -f "$worker"

# Database boundary and idempotency invariants.
grep -q 'unique (notification_id, device_id)' "$migration"
grep -q "auth.role() <> 'service_role'" "$migration"
grep -q "p_batch_size > 100" "$migration"
grep -q 'for update of delivery skip locked' "$migration"
grep -q 'NoLongerEligible' "$migration"
grep -q "v_attempt >= 8" "$migration"
grep -q "not p_retryable" "$migration"
grep -q 'enabled = false, invalidated_at = now()' "$migration"
grep -q 'revoke all on public.notification_deliveries' "$migration"

# Worker security, APNs environments, token hygiene, and retry behavior.
grep -q 'constantTimeEqual' "$worker"
grep -q 'authorization.startsWith("Bearer ")' "$worker"
grep -q 'APNS_WORKER_SECRET' "$worker"
grep -q 'APNS_PRIVATE_KEY' "$worker"
grep -q 'https://api.push.apple.com' "$worker"
grep -q 'https://api.sandbox.push.apple.com' "$worker"
grep -q 'retry-after' "$worker"
grep -q 'BadDeviceToken' "$worker"
grep -q 'Unregistered' "$worker"
grep -q 'Never log the delivery object' "$worker"
! grep -Eq 'console\.(log|error)\([^\n]*(device_token|delivery\.device_token)' "$worker"
grep -q 'profile_id: delivery.actor_id' "$worker"

for secret in APNS_TEAM_ID APNS_KEY_ID APNS_PRIVATE_KEY APNS_WORKER_SECRET; do
  grep -q "^${secret}=" "$env_example"
done

echo "APNs delivery static checks passed"
