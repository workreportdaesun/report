-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_RLS_DELETE_GUARD.sql
-- 익명 키로 데이터를 통째로 지울 수 없게 막는다
--
-- 작성 2026-08-14 / 개선 우선순위 1번
--
-- 【왜 필요한가 — 실측】
--   publishable 키는 8개 앱 소스에 하드코딩돼 있고 저장소가 public 이라 사실상 공개다.
--   그 키로 직접 REST 를 호출해본 결과:
--       POST   /rest/v1/daily_reports  → INSERT 성공
--       DELETE /rest/v1/daily_reports  → HTTP 204 (삭제됨)
--   즉 키를 아는 누구나 작업일보 전체를 지울 수 있는 상태였다.
--   (탐침용으로 넣은 행은 즉시 삭제했고 기존 15건은 그대로임을 확인했다)
--
-- 【이 파일이 하는 것 / 안 하는 것】
--   하는 것   : 앱이 실제로 쓰지 않는 DELETE 를 차단한다. 최악(대량 삭제)을 막는다.
--   안 하는 것: 위조·무단 조회는 여전히 가능하다. 그걸 막으려면 Supabase Auth +
--               auth.uid() 기반 정책으로 가야 하고, 그건 9개 앱 로그인을 전부 바꿔야 한다.
--   → 비용 대비 효과가 가장 큰 한 걸음이지 완결된 보안 대책이 아니다.
--
-- 【DELETE 허용 여부는 코드 실사용으로 정했다】
--   전 앱에서 .delete() 를 쓰는 곳은 아래 3개 테이블뿐이다.
--       members                    report/app/admin.html:1144, app/index.html:3204·3242, shoot:363
--       material_moves             material:976
--       workreportdaesun-gallery   gallery:3127·3128
--   나머지 테이블은 어느 앱도 삭제하지 않으므로 막아도 동작에 영향이 없다.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. DELETE 차단 대상 — 앱이 삭제하지 않는 테이블
--    SELECT / INSERT / UPDATE 는 지금과 똑같이 허용한다
-- ───────────────────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array[
    'daily_reports',        -- ★ 작업일보 원본. 가장 중요하고 삭제 코드가 아예 없다
    'app_settings',         -- 8개 앱 공용 설정
    'progress_checklist',
    'attendance_manual',
    'work_log',
    'plan_items',
    'contract_items',       -- 오늘 만든 기성 계층
    'indirect_items',
    'payment_periods',
    'payment_lines',
    'payment_report_link'
  ]
  loop
    -- 테이블이 없으면 조용히 건너뛴다 (환경마다 일부만 있을 수 있음)
    if to_regclass('public.'||t) is null then
      raise notice '건너뜀 (없는 테이블): %', t;
      continue;
    end if;

    execute format('alter table public.%I enable row level security', t);

    -- 오늘 먼저 만들어둔 전체허용 정책이 있으면 걷어낸다 (DELETE 까지 열려 있음)
    execute format('drop policy if exists %I on public.%I', t||'_anon_all', t);
    execute format('drop policy if exists %I on public.%I', t||'_read',   t);
    execute format('drop policy if exists %I on public.%I', t||'_insert', t);
    execute format('drop policy if exists %I on public.%I', t||'_update', t);

    execute format('create policy %I on public.%I for select to anon, authenticated using (true)',
                   t||'_read', t);
    execute format('create policy %I on public.%I for insert to anon, authenticated with check (true)',
                   t||'_insert', t);
    execute format('create policy %I on public.%I for update to anon, authenticated using (true) with check (true)',
                   t||'_update', t);
    -- DELETE 정책은 만들지 않는다 → RLS 가 켜져 있으므로 익명 삭제는 전부 거부된다
  end loop;
end $$;


-- ───────────────────────────────────────────────────────────────────
-- 2. DELETE 허용 대상 — 앱이 실제로 삭제 기능을 쓰는 테이블
--    (회원 삭제/탈퇴, 자재 전표 삭제, 사진 삭제)
--    여기는 여전히 익명 삭제가 가능하다는 점을 알고 있어야 한다.
-- ───────────────────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array[
    'members',
    'material_moves',
    'workreportdaesun-gallery'
  ]
  loop
    if to_regclass(format('public.%I', t)) is null then
      raise notice '건너뜀 (없는 테이블): %', t;
      continue;
    end if;

    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_all', t);
    execute format('create policy %I on public.%I for all to anon, authenticated using (true) with check (true)',
                   t||'_all', t);
  end loop;
end $$;


-- ───────────────────────────────────────────────────────────────────
-- 확인
-- ───────────────────────────────────────────────────────────────────
-- 정책 목록 — daily_reports 에 select/insert/update 3개만 있고 delete 가 없어야 한다
--   select tablename, policyname, cmd from pg_policies
--    where schemaname='public' order by tablename, cmd;
--
-- RLS 활성 여부
--   select relname, relrowsecurity from pg_class
--    where relnamespace='public'::regnamespace and relkind='r' order by relname;
