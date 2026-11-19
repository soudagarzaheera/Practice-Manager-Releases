-- ==============================================================================
-- 053: CLIENTS ARE SHARED BY EVERY COMPANY OF AN ORGANIZATION
-- ==============================================================================
-- Audit (live DB, 2026-11-18):
--   * clients_select (028) = organization AND (auth_company_ok(company_id) OR
--     auth_client_visible(id)). auth_company_ok() is true for every company
--     only for Partners; everyone else saw just their own company's clients
--     (plus clients of jobs they work on). One organization had 89 clients on
--     MRCO and 2 on FYN - FYN's staff could not see any MRCO client.
--   * clients_update (036) and auth_client_visible() (028, also used by
--     statutory_compliances) had the same company restriction.
--   * statutory_dates_client_company (034) forced a statutory date onto its
--     client's company, which (with shared clients) would move a Company B
--     user's date into Company A, where they can no longer see or edit it.
--
-- After this migration:
--   * SELECT: any signed-in member of the organization sees all of that
--     organization's clients. auth_org_id() comes from the caller's own active
--     profile (auth.uid()), never from anything the browser sends, so another
--     organization still sees nothing.
--   * UPDATE: Assistant Manager and above (rank >= 60, unchanged) of the same
--     organization, whichever company recorded the client. Moving a client to
--     another company stays Partner-only (trg_clients_company, 028); archiving
--     stays Partner-only (trg_guard_client_archive, 036).
--   * INSERT and DELETE are unchanged: a new client is recorded under the
--     creator's own company (now only "the company that added it"), rank >= 60;
--     deleting stays Partner-only.
--   * auth_client_visible(): organization-wide, like the client itself.
--   * statutory_dates: a date keeps the company it was saved under; the client's
--     company is used only when no company was given. Existing rows untouched.
--
-- No column, row, id or foreign key is changed. clients.company_id stays (NOT
-- NULL) as a record of which company added the client. Re-runnable.
-- Apply with:  supabase db query --linked -f supabase/migrations/053_org_shared_clients.sql
-- ==============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.auth_org_id()') IS NULL OR to_regprocedure('public.auth_rank()') IS NULL
     OR to_regprocedure('public.auth_company_ok(uuid)') IS NULL THEN
    RAISE EXCEPTION '053 requires 003, 005 and 028 to be applied first.';
  END IF;
END $$;

-- 1. clients RLS ----------------------------------------------------------------
DROP POLICY IF EXISTS clients_select ON clients;
CREATE POLICY clients_select ON clients FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());

DROP POLICY IF EXISTS clients_update ON clients;
CREATE POLICY clients_update ON clients FOR UPDATE TO authenticated
  USING      (organization_id = auth_org_id() AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);

-- clients_insert (036: own company, rank >= 60) and clients_delete (036:
-- Partner) are intentionally left as they are.

-- 2. auth_client_visible(): same organization -----------------------------------
CREATE OR REPLACE FUNCTION auth_client_visible(p_client UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM clients c WHERE c.id = p_client AND c.organization_id = auth_org_id());
$$;
REVOKE ALL ON FUNCTION auth_client_visible(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION auth_client_visible(uuid) TO authenticated;

-- 3. statutory dates: keep the chosen company -----------------------------------
CREATE OR REPLACE FUNCTION statutory_dates_client_company()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.client_id IS NOT NULL AND NEW.company_id IS NULL THEN
    SELECT company_id INTO NEW.company_id FROM clients
     WHERE id = NEW.client_id AND organization_id = NEW.organization_id;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION statutory_dates_client_company() FROM PUBLIC, anon, authenticated;

COMMIT;
