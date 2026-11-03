-- Prevent permanent deletion of financial expense records.
-- Corrections must be represented by an auditable reversal workflow.
drop policy if exists cloud_expenses_delete_authorized on public.cloud_expenses;
revoke delete on public.cloud_expenses from anon, authenticated;

comment on table public.cloud_expenses is
  'Financial expense records are append-oriented. Permanent client-side deletion is disabled; corrections must use an audited reversal workflow.';
