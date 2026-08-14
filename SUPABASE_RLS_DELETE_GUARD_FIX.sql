-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_RLS_DELETE_GUARD_FIX.sql
-- 보호 대상 테이블에 남아 있는 DELETE/ALL 정책을 이름과 무관하게 전부 제거
--
-- 작성 2026-08-14 / SUPABASE_RLS_DELETE_GUARD.sql 실행 후 후속
--
-- 【왜 필요한가】
--   DELETE_GUARD 를 실행한 뒤 public 스키마의 DELETE/ALL 정책이 8개로 집계됐다.
--   의도한 값은 3개(members / material_moves / workreportdaesun-gallery)다.
--   초과분의 정체는 둘 중 하나인데, 어느 쪽이든 아래 방식으로 한 번에 정리된다.
--     ① 앞서 실행한 SUPABASE_PAYMENT_RLS.sql 이 만든 *_anon_all (for all) 잔재
--     ② 이름이 달라 drop policy if exists 로 못 잡은 예전 정책
--
--   이 파일은 정책 "이름"을 가정하지 않는다. 보호 대상 테이블에 걸린 DELETE·ALL
--   정책을 pg_policies 에서 찾아 전부 지우고, SELECT/INSERT/UPDATE 만 다시 만든다.
--   그래서 몇 번을 실행해도 같은 상태가 된다.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare
  t   text;
  pol record;
  protected text[] := array[
    'daily_reports','app_settings','progress_checklist','attendance_manual',
    'work_log','plan_items','contract_items','indirect_items',
    'payment_periods','payment_lines','payment_report_link'
  ];
begin
  foreach t in array protected
  loop
    if to_regclass(format('public.%I', t)) is null then
      raise notice '건너뜀 (없는 테이블): %', t;
      continue;
    end if;

    execute format('alter table public.%I enable row level security', t);

    -- 이름과 무관하게 DELETE·ALL 정책을 전부 제거한다
    for pol in
      select policyname from pg_policies
       where schemaname = 'public' and tablename = t and cmd in ('DELETE','ALL')
    loop
      execute format('drop policy %I on public.%I', pol.policyname, t);
      raise notice '제거: %.% (%)', t, pol.policyname, 'DELETE/ALL';
    end loop;

    -- 앱이 쓰는 3개 명령만 다시 만든다 (있으면 지우고 새로)
    execute format('drop policy if exists %I on public.%I', t||'_read',   t);
    execute format('drop policy if exists %I on public.%I', t||'_insert', t);
    execute format('drop policy if exists %I on public.%I', t||'_update', t);

    execute format('create policy %I on public.%I for select to anon, authenticated using (true)',
                   t||'_read', t);
    execute format('create policy %I on public.%I for insert to anon, authenticated with check (true)',
                   t||'_insert', t);
    execute format('create policy %I on public.%I for update to anon, authenticated using (true) with check (true)',
                   t||'_update', t);
  end loop;
end $$;


-- ───────────────────────────────────────────────────────────────────
-- 결과 확인 — 이 select 가 바로 결과를 보여준다
--   기대: 보호대상_삭제허용 = 0
--         전체_삭제허용     = 3  (members / material_moves / workreportdaesun-gallery)
--         RLS꺼진테이블     = 0
-- ───────────────────────────────────────────────────────────────────
select
  (select count(*) from pg_policies
    where schemaname='public' and cmd in ('DELETE','ALL')
      and tablename in ('daily_reports','app_settings','progress_checklist','attendance_manual',
                        'work_log','plan_items','contract_items','indirect_items',
                        'payment_periods','payment_lines','payment_report_link')
  ) as "보호대상_삭제허용",
  (select count(*) from pg_policies
    where schemaname='public' and cmd in ('DELETE','ALL')
  ) as "전체_삭제허용",
  (select string_agg(distinct tablename, ', ' order by tablename) from pg_policies
    where schemaname='public' and cmd in ('DELETE','ALL')
  ) as "삭제허용_테이블",
  (select count(*) from pg_class
    where relnamespace='public'::regnamespace and relkind='r' and not relrowsecurity
  ) as "RLS꺼진테이블",
  (select string_agg(relname, ', ' order by relname) from pg_class
    where relnamespace='public'::regnamespace and relkind='r' and not relrowsecurity
  ) as "RLS꺼진_테이블목록";
