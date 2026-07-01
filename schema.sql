
-- ============ ROLES ============
CREATE TYPE public.app_role AS ENUM ('admin', 'team', 'principal', 'parent');

CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  school_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, role, school_id)
);
GRANT SELECT ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role public.app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

CREATE OR REPLACE FUNCTION public.is_team_or_admin(_user_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role IN ('admin','team'))
$$;

CREATE OR REPLACE FUNCTION public.principal_school(_user_id UUID)
RETURNS UUID LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT school_id FROM public.user_roles WHERE user_id = _user_id AND role = 'principal' LIMIT 1
$$;

CREATE POLICY "view own roles" ON public.user_roles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_team_or_admin(auth.uid()));

-- ============ CORE ============
CREATE TABLE public.schools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  code TEXT UNIQUE NOT NULL,
  address TEXT,
  phone TEXT,
  email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.schools TO authenticated;
GRANT ALL ON public.schools TO service_role;
ALTER TABLE public.schools ENABLE ROW LEVEL SECURITY;
CREATE POLICY "team admin all schools" ON public.schools FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));
CREATE POLICY "principal sees own school" ON public.schools FOR SELECT TO authenticated
  USING (id = public.principal_school(auth.uid()));
CREATE POLICY "any auth read school basic" ON public.schools FOR SELECT TO authenticated USING (true);

CREATE TABLE public.students (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  admission_no TEXT NOT NULL,
  full_name TEXT NOT NULL,
  class TEXT,
  section TEXT,
  dob DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (school_id, admission_no)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.students TO authenticated;
GRANT ALL ON public.students TO service_role;
ALTER TABLE public.students ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.parents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  phone TEXT UNIQUE NOT NULL,
  full_name TEXT,
  email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.parents TO authenticated;
GRANT ALL ON public.parents TO service_role;
ALTER TABLE public.parents ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.parent_student_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id UUID NOT NULL REFERENCES public.parents(id) ON DELETE CASCADE,
  student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  relation TEXT,
  is_primary BOOLEAN NOT NULL DEFAULT false,
  UNIQUE (parent_id, student_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.parent_student_links TO authenticated;
GRANT ALL ON public.parent_student_links TO service_role;
ALTER TABLE public.parent_student_links ENABLE ROW LEVEL SECURITY;

-- helper: can current user view this student?
CREATE OR REPLACE FUNCTION public.can_view_student(_student_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    public.is_team_or_admin(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.students s
      WHERE s.id = _student_id AND s.school_id = public.principal_school(auth.uid())
    )
    OR EXISTS (
      SELECT 1 FROM public.parent_student_links psl
      JOIN public.parents p ON p.id = psl.parent_id
      WHERE psl.student_id = _student_id AND p.user_id = auth.uid()
    )
$$;

CREATE POLICY "view students" ON public.students FOR SELECT TO authenticated
  USING (public.can_view_student(id));
CREATE POLICY "team admin write students" ON public.students FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE POLICY "view own parent" ON public.parents FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_team_or_admin(auth.uid()));
CREATE POLICY "team admin write parents" ON public.parents FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE POLICY "view links" ON public.parent_student_links FOR SELECT TO authenticated
  USING (
    public.is_team_or_admin(auth.uid())
    OR EXISTS (SELECT 1 FROM public.parents p WHERE p.id = parent_id AND p.user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.students s WHERE s.id = student_id AND s.school_id = public.principal_school(auth.uid()))
  );
CREATE POLICY "team admin write links" ON public.parent_student_links FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.principals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.principals TO authenticated;
GRANT ALL ON public.principals TO service_role;
ALTER TABLE public.principals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view principal" ON public.principals FOR SELECT TO authenticated
  USING (public.is_team_or_admin(auth.uid()) OR user_id = auth.uid() OR school_id = public.principal_school(auth.uid()));
CREATE POLICY "team admin write principals" ON public.principals FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.team_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID UNIQUE NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  department TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.team_members TO authenticated;
GRANT ALL ON public.team_members TO service_role;
ALTER TABLE public.team_members ENABLE ROW LEVEL SECURITY;
CREATE POLICY "team admin all team" ON public.team_members FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

-- ============ SCHOOL DATA ============
CREATE TABLE public.fees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  term TEXT NOT NULL,
  amount_due NUMERIC(12,2) NOT NULL DEFAULT 0,
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  due_date DATE,
  status TEXT NOT NULL DEFAULT 'pending',
  last_payment_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.fees TO authenticated;
GRANT ALL ON public.fees TO service_role;
ALTER TABLE public.fees ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view fees" ON public.fees FOR SELECT TO authenticated USING (public.can_view_student(student_id));
CREATE POLICY "team admin write fees" ON public.fees FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.attendance (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  status TEXT NOT NULL,
  remarks TEXT,
  UNIQUE (student_id, date)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.attendance TO authenticated;
GRANT ALL ON public.attendance TO service_role;
ALTER TABLE public.attendance ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view attendance" ON public.attendance FOR SELECT TO authenticated USING (public.can_view_student(student_id));
CREATE POLICY "team admin write attendance" ON public.attendance FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.homework (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  class TEXT NOT NULL,
  section TEXT,
  subject TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  due_date DATE,
  assigned_date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.homework TO authenticated;
GRANT ALL ON public.homework TO service_role;
ALTER TABLE public.homework ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view homework" ON public.homework FOR SELECT TO authenticated USING (
  public.is_team_or_admin(auth.uid())
  OR school_id = public.principal_school(auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.parent_student_links psl
    JOIN public.parents p ON p.id = psl.parent_id
    JOIN public.students s ON s.id = psl.student_id
    WHERE p.user_id = auth.uid() AND s.school_id = homework.school_id
      AND s.class = homework.class AND (homework.section IS NULL OR s.section = homework.section)
  )
);
CREATE POLICY "team admin write homework" ON public.homework FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.marks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  exam TEXT NOT NULL,
  subject TEXT NOT NULL,
  marks_obtained NUMERIC(6,2) NOT NULL,
  max_marks NUMERIC(6,2) NOT NULL,
  grade TEXT,
  exam_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.marks TO authenticated;
GRANT ALL ON public.marks TO service_role;
ALTER TABLE public.marks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view marks" ON public.marks FOR SELECT TO authenticated USING (public.can_view_student(student_id));
CREATE POLICY "team admin write marks" ON public.marks FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.events_holidays (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  kind TEXT NOT NULL DEFAULT 'event',
  start_date DATE NOT NULL,
  end_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.events_holidays TO authenticated;
GRANT ALL ON public.events_holidays TO service_role;
ALTER TABLE public.events_holidays ENABLE ROW LEVEL SECURITY;
CREATE POLICY "any auth view events" ON public.events_holidays FOR SELECT TO authenticated USING (true);
CREATE POLICY "team admin write events" ON public.events_holidays FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.school_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID UNIQUE NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  timings TEXT,
  uniform_policy TEXT,
  transport_info TEXT,
  contact_info TEXT,
  extra JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.school_settings TO authenticated;
GRANT ALL ON public.school_settings TO service_role;
ALTER TABLE public.school_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "any auth view settings" ON public.school_settings FOR SELECT TO authenticated USING (true);
CREATE POLICY "team admin write settings" ON public.school_settings FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

-- ============ CHAT ============
CREATE TABLE public.conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id UUID REFERENCES public.parents(id) ON DELETE CASCADE,
  principal_id UUID REFERENCES public.principals(id) ON DELETE CASCADE,
  school_id UUID REFERENCES public.schools(id) ON DELETE CASCADE,
  channel TEXT NOT NULL DEFAULT 'whatsapp',
  status TEXT NOT NULL DEFAULT 'open',
  last_message_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.conversations TO authenticated;
GRANT ALL ON public.conversations TO service_role;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view conv" ON public.conversations FOR SELECT TO authenticated USING (
  public.is_team_or_admin(auth.uid())
  OR school_id = public.principal_school(auth.uid())
  OR EXISTS (SELECT 1 FROM public.parents p WHERE p.id = parent_id AND p.user_id = auth.uid())
  OR EXISTS (SELECT 1 FROM public.principals pr WHERE pr.id = principal_id AND pr.user_id = auth.uid())
);
CREATE POLICY "team admin write conv" ON public.conversations FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_kind TEXT NOT NULL,
  sender_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  content TEXT NOT NULL,
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.messages TO authenticated;
GRANT ALL ON public.messages TO service_role;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view msg via conv" ON public.messages FOR SELECT TO authenticated USING (
  EXISTS (
    SELECT 1 FROM public.conversations c WHERE c.id = conversation_id AND (
      public.is_team_or_admin(auth.uid())
      OR c.school_id = public.principal_school(auth.uid())
      OR EXISTS (SELECT 1 FROM public.parents p WHERE p.id = c.parent_id AND p.user_id = auth.uid())
      OR EXISTS (SELECT 1 FROM public.principals pr WHERE pr.id = c.principal_id AND pr.user_id = auth.uid())
    )
  )
);
CREATE POLICY "team admin write msg" ON public.messages FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.escalations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID REFERENCES public.conversations(id) ON DELETE SET NULL,
  school_id UUID REFERENCES public.schools(id) ON DELETE CASCADE,
  parent_id UUID REFERENCES public.parents(id) ON DELETE SET NULL,
  principal_id UUID REFERENCES public.principals(id) ON DELETE SET NULL,
  kind TEXT NOT NULL,
  category TEXT,
  priority TEXT NOT NULL DEFAULT 'normal',
  sentiment TEXT,
  status TEXT NOT NULL DEFAULT 'open',
  summary TEXT NOT NULL,
  assigned_to UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.escalations TO authenticated;
GRANT ALL ON public.escalations TO service_role;
ALTER TABLE public.escalations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view esc" ON public.escalations FOR SELECT TO authenticated USING (
  public.is_team_or_admin(auth.uid())
  OR school_id = public.principal_school(auth.uid())
  OR EXISTS (SELECT 1 FROM public.parents p WHERE p.id = parent_id AND p.user_id = auth.uid())
);
CREATE POLICY "team admin write esc" ON public.escalations FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

CREATE TABLE public.notifications_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  recipient_phone TEXT,
  channel TEXT NOT NULL,
  template TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'queued',
  error TEXT,
  related_escalation_id UUID REFERENCES public.escalations(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.notifications_log TO authenticated;
GRANT ALL ON public.notifications_log TO service_role;
ALTER TABLE public.notifications_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view own notif" ON public.notifications_log FOR SELECT TO authenticated
  USING (recipient_user_id = auth.uid() OR public.is_team_or_admin(auth.uid()));
CREATE POLICY "team admin write notif" ON public.notifications_log FOR ALL TO authenticated
  USING (public.is_team_or_admin(auth.uid())) WITH CHECK (public.is_team_or_admin(auth.uid()));

-- ============ PHASE 2 (MODIFIED DATA)============

REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_team_or_admin(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.principal_school(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.can_view_student(uuid) FROM PUBLIC, anon;

-- ============ PHASE 3 (CHANGED DATA) ============

WITH s AS (
  INSERT INTO public.schools (name, code, address, phone, email)
  VALUES ('Titus Demo Public School', 'TDPS001', '123 Demo Road, Bengaluru', '+919999999999', 'info@tdps.demo')
  RETURNING id
),
stu AS (
  INSERT INTO public.students (school_id, admission_no, full_name, class, section, dob)
  SELECT s.id, v.admission_no, v.full_name, v.class, v.section, v.dob::date
  FROM s, (VALUES
    ('TDPS-001','Aarav Sharma','5','A','2014-03-12'),
    ('TDPS-002','Ishita Reddy','5','B','2014-07-22'),
    ('TDPS-003','Kabir Khan','6','A','2013-11-05'),
    ('TDPS-004','Meera Iyer','7','C','2012-09-30'),
    ('TDPS-005','Rohan Verma','8','A','2011-01-18')
  ) AS v(admission_no, full_name, class, section, dob)
  RETURNING id, admission_no
),
fees_ins AS (
  INSERT INTO public.fees (student_id, term, amount_due, amount_paid, due_date, status, last_payment_date)
  SELECT stu.id, 'Term 1 2026-27', 25000, 25000, '2026-04-15', 'paid', '2026-04-10' FROM stu
  UNION ALL
  SELECT stu.id, 'Term 2 2026-27', 25000,
    CASE WHEN stu.admission_no IN ('TDPS-001','TDPS-003') THEN 25000 ELSE 0 END,
    '2026-07-15',
    CASE WHEN stu.admission_no IN ('TDPS-001','TDPS-003') THEN 'paid' ELSE 'pending' END,
    CASE WHEN stu.admission_no IN ('TDPS-001','TDPS-003') THEN '2026-07-10'::date ELSE NULL END
  FROM stu
  RETURNING id
),
att_ins AS (
  INSERT INTO public.attendance (student_id, date, status)
  SELECT stu.id, d::date,
    CASE
      WHEN stu.admission_no = 'TDPS-004' AND d::date IN ('2026-06-22','2026-06-25') THEN 'absent'
      WHEN stu.admission_no = 'TDPS-002' AND d::date = '2026-06-24' THEN 'late'
      ELSE 'present'
    END
  FROM stu, generate_series('2026-06-22'::date, '2026-06-26'::date, '1 day'::interval) d
  RETURNING id
),
settings_ins AS (
  INSERT INTO public.school_settings (school_id, timings, uniform_policy, transport_info, contact_info)
  SELECT s.id, '8:00 AM - 2:30 PM (Mon-Fri)',
    'Blue shirt, navy trousers/skirt. Sports uniform on Wednesdays.',
    'School bus available on 6 routes across the city. Contact transport@tdps.demo',
    'Front office: +91 99999 99999, Mon-Sat 9 AM - 4 PM'
  FROM s RETURNING id
)
INSERT INTO public.events_holidays (school_id, title, description, kind, start_date, end_date)
SELECT s.id, v.title, v.description, v.kind, v.start_date::date, v.end_date::date
FROM s, (VALUES
  ('Independence Day Holiday','School closed','holiday','2026-08-15','2026-08-15'),
  ('Annual Sports Day','All students to wear sports uniform','event','2026-09-12','2026-09-12'),
  ('Parent-Teacher Meeting','Class 5-8 PTM','event','2026-07-20','2026-07-20')
) AS v(title, description, kind, start_date, end_date);

-- ============ PHASE 4 (CHANGED DATA) ============

WITH s AS (
  INSERT INTO public.schools (name, code, address, phone, email)
  VALUES ('Titus Demo Public School', 'TDPS001', '123 Demo Road, Bengaluru', '+919999999999', 'info@tdps.demo')
  RETURNING id
),
stu AS (
  INSERT INTO public.students (school_id, admission_no, full_name, class, section, dob)
  SELECT s.id, v.admission_no, v.full_name, v.class, v.section, v.dob::date
  FROM s, (VALUES
    ('TDPS-001','Aarav Sharma','5','A','2014-03-12'),
    ('TDPS-002','Ishita Reddy','5','B','2014-07-22'),
    ('TDPS-003','Kabir Khan','6','A','2013-11-05'),
    ('TDPS-004','Meera Iyer','7','C','2012-09-30'),
    ('TDPS-005','Rohan Verma','8','A','2011-01-18')
  ) AS v(admission_no, full_name, class, section, dob)
  RETURNING id, admission_no
),
fees_ins AS (
  INSERT INTO public.fees (student_id, term, amount_due, amount_paid, due_date, status, last_payment_date)
  SELECT stu.id, 'Term 1 2026-27', 25000, 25000, '2026-04-15'::date, 'paid', '2026-04-10'::date FROM stu
  UNION ALL
  SELECT stu.id, 'Term 2 2026-27', 25000,
    CASE WHEN stu.admission_no IN ('TDPS-001','TDPS-003') THEN 25000 ELSE 0 END,
    '2026-07-15'::date,
    CASE WHEN stu.admission_no IN ('TDPS-001','TDPS-003') THEN 'paid' ELSE 'pending' END,
    CASE WHEN stu.admission_no IN ('TDPS-001','TDPS-003') THEN '2026-07-10'::date ELSE NULL END
  FROM stu
  RETURNING id
),
att_ins AS (
  INSERT INTO public.attendance (student_id, date, status)
  SELECT stu.id, d::date,
    CASE
      WHEN stu.admission_no = 'TDPS-004' AND d::date IN ('2026-06-22'::date,'2026-06-25'::date) THEN 'absent'
      WHEN stu.admission_no = 'TDPS-002' AND d::date = '2026-06-24'::date THEN 'late'
      ELSE 'present'
    END
  FROM stu, generate_series('2026-06-22'::date, '2026-06-26'::date, '1 day'::interval) d
  RETURNING id
),
settings_ins AS (
  INSERT INTO public.school_settings (school_id, timings, uniform_policy, transport_info, contact_info)
  SELECT s.id, '8:00 AM - 2:30 PM (Mon-Fri)',
    'Blue shirt, navy trousers/skirt. Sports uniform on Wednesdays.',
    'School bus available on 6 routes. Contact transport@tdps.demo',
    'Front office: +91 99999 99999, Mon-Sat 9 AM - 4 PM'
  FROM s RETURNING id
)
INSERT INTO public.events_holidays (school_id, title, description, kind, start_date, end_date)
SELECT s.id, v.title, v.description, v.kind, v.start_date::date, v.end_date::date
FROM s, (VALUES
  ('Independence Day Holiday','School closed','holiday','2026-08-15','2026-08-15'),
  ('Annual Sports Day','Wear sports uniform','event','2026-09-12','2026-09-12'),
  ('Parent-Teacher Meeting','Class 5-8 PTM','event','2026-07-20','2026-07-20')
) AS v(title, description, kind, start_date, end_date);
