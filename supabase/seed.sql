-- seed.sql — default production departments (safe to re-run). Edit names/modes freely later
-- from the admin screen; more departments per stage (e.g. two sewing lines) are allowed.
INSERT INTO factory.departments (code, name_ar, stage, custody_mode) VALUES
  ('CUTTING',     'قسم القص',          'CUTTING',     'SHARED'),
  ('SEWING',      'قسم الخياطة',        'SEWING',      'INDIVIDUAL'),
  ('FINISHING_1', 'التشطيب الأول',      'FINISHING_1', 'SHARED'),
  ('IRONING',     'قسم الكي',          'IRONING',     'SHARED'),
  ('FINISHING_2', 'التشطيب الثاني',     'FINISHING_2', 'SHARED'),
  ('WAREHOUSE',   'المخزن والتسليم',    'WAREHOUSE',   'SHARED')
ON CONFLICT (code) DO NOTHING;

INSERT INTO factory.custodies (kind, department_id)
SELECT 'DEPARTMENT', id FROM factory.departments
ON CONFLICT (department_id) WHERE kind = 'DEPARTMENT' DO NOTHING;
