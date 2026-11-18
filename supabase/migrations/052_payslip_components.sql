-- ==============================================================================
-- 052: PAYSLIP EARNINGS & DEDUCTIONS (partner-entered)
-- ==============================================================================
-- Inspected first: payslips are not stored. index.html builds them from
-- employee_salary_history (CTC) plus attendance (salaryCalculation()). That
-- calculation, the Salary screen and every existing table stay unchanged.
--
-- Adds one table holding the amounts a Partner types in for an employee's
-- payslip for one month:
--   Earnings   basic, sa, la, ca, hra
--   Deductions tds, pf, pt, other_deductions (+ other_deduction_remark)
--   payment_date (optional, printed as "Date of payment")
-- Nothing is calculated or stored here except what the Partner enters; the app
-- adds the earnings, adds the deductions and subtracts - no rates or rules.
-- A month with no row keeps showing the existing attendance-based payslip, so
-- payslip history is unchanged.
--
-- Rules:
--   * Every amount is NULL (left blank) or >= 0.
--   * other_deductions > 0 requires a non-blank other_deduction_remark.
--   * One row per employee per month (salary_month = first day of the month).
-- Access (RLS):
--   * Partners: read and write, own organization (same as salary_partner_only).
--   * Everyone else: read their OWN rows only (same as salary_own_select, 029).
--
-- Additive and re-runnable. Apply with:
--   supabase db query --linked -f supabase/migrations/052_payslip_components.sql
-- ==============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS employee_payslip_components (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id        UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id             UUID NOT NULL,
  salary_month           DATE NOT NULL,
  basic                  NUMERIC(12,2),
  sa                     NUMERIC(12,2),
  la                     NUMERIC(12,2),
  ca                     NUMERIC(12,2),
  hra                    NUMERIC(12,2),
  tds                    NUMERIC(12,2),
  pf                     NUMERIC(12,2),
  pt                     NUMERIC(12,2),
  other_deductions       NUMERIC(12,2),
  other_deduction_remark TEXT,
  payment_date           DATE,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by             UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by             UUID REFERENCES profiles(id) ON DELETE SET NULL,
  CONSTRAINT fk_payslip_components_profile FOREIGN KEY (organization_id, profile_id)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT uq_payslip_components_month UNIQUE (profile_id, salary_month),
  CONSTRAINT chk_payslip_components_month CHECK (EXTRACT(DAY FROM salary_month) = 1),
  CONSTRAINT chk_payslip_components_amounts CHECK (
    COALESCE(basic,0) >= 0 AND COALESCE(sa,0) >= 0 AND COALESCE(la,0) >= 0 AND
    COALESCE(ca,0) >= 0 AND COALESCE(hra,0) >= 0 AND COALESCE(tds,0) >= 0 AND
    COALESCE(pf,0) >= 0 AND COALESCE(pt,0) >= 0 AND COALESCE(other_deductions,0) >= 0
  ),
  CONSTRAINT chk_payslip_components_remark CHECK (
    COALESCE(other_deductions,0) = 0
    OR length(btrim(COALESCE(other_deduction_remark,''))) > 0
  ),
  CONSTRAINT chk_payslip_components_remark_len CHECK (
    other_deduction_remark IS NULL OR length(other_deduction_remark) <= 500
  )
);

CREATE INDEX IF NOT EXISTS idx_payslip_components_month
  ON employee_payslip_components (organization_id, salary_month);

ALTER TABLE employee_payslip_components ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS payslip_components_partner_all ON employee_payslip_components;
CREATE POLICY payslip_components_partner_all ON employee_payslip_components FOR ALL TO authenticated
  USING (organization_id = auth_org_id() AND auth_is_partner())
  WITH CHECK (organization_id = auth_org_id() AND auth_is_partner());

DROP POLICY IF EXISTS payslip_components_own_select ON employee_payslip_components;
CREATE POLICY payslip_components_own_select ON employee_payslip_components FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND profile_id = auth_profile_id());

REVOKE ALL ON employee_payslip_components FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON employee_payslip_components TO authenticated;

COMMIT;
