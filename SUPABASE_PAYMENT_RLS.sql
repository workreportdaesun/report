-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_PAYMENT_RLS.sql
-- 1) 기성 테이블 RLS 정책 — 앱이 읽고 쓸 수 있게 한다
-- 2) close_payment_period 를 계정 비연동 버전으로 교체
--
-- 작성 2026-08-14 / 적용 순서 7번 (SUPABASE_기성계층_ALL.sql 실행 후)
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. RLS 정책
--
-- 【왜 필요한가】
--   SQL Editor 로 만든 신규 테이블에 RLS 가 켜진 채 정책이 없어서,
--   publishable(anon) 키를 쓰는 앱이 테이블에 직접 접근하지 못했다.
--     · SELECT → 오류 없이 빈 배열 [] 만 돌아온다 (원인 파악이 어려운 형태)
--     · INSERT → 42501 new row violates row-level security policy
--   실제로 간접비 7종은 정상 삽입됐는데도 REST 로는 [] 로 보였다.
--   (뷰는 소유자 권한으로 실행되어 RLS 를 우회하므로 v_indirect_progress 로는 보였다)
--
-- 【이 프로젝트의 접근 모델】
--   기성관리 앱은 계정 연동을 하지 않는다. 공무 담당자만 공용 암호로 들어와서 쓰고,
--   Supabase 는 publishable 키 하나로 접속한다(다른 앱들과 동일).
--   따라서 테이블도 그 키로 접근 가능해야 한다.
--
--   ⚠️ 이건 화면 감추기 수준의 보호다. 키를 아는 사람은 계약단가를 읽을 수 있다.
--      실제 차단이 필요해지면 Supabase Auth 도입 후 auth.uid() 기반 정책으로 바꿔야 한다.
-- ───────────────────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array[
    'contract_items','indirect_items','payment_periods','payment_lines','payment_report_link'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_anon_all', t);
    execute format(
      'create policy %I on public.%I for all to anon, authenticated using (true) with check (true)',
      t||'_anon_all', t);
  end loop;
end $$;


-- ───────────────────────────────────────────────────────────────────
-- 2. close_payment_period — 계정 비연동 버전
--
-- 기존 버전은 p_actor_id 로 members 를 조회해 role='admin' 인지 확인했다.
-- 기성관리 앱은 계정 연동을 하지 않으므로(공무 공용 암호로만 들어옴) 그 검사를 뺀다.
-- 담당자는 이름 문자열만 받아 closed_by 에 기록한다(감사 추적용).
--
-- 인자 이름이 p_actor_id → p_actor 로 바뀌므로 옛 함수는 지운다.
-- (PostgreSQL 은 인자 이름이 다르면 다른 함수로 보고 둘 다 남겨 두기 때문에,
--  지우지 않으면 앱이 어느 쪽을 부를지 모호해진다)
-- ───────────────────────────────────────────────────────────────────
drop function if exists public.close_payment_period(bigint, text);

create or replace function public.close_payment_period(
  p_period_id bigint,
  p_actor     text default '공무'
) returns table (linked_reports integer, billed_lines integer, uncontracted integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p       public.payment_periods;
  v_reports integer;
  v_lines   integer;
  v_unc     integer;
begin
  select * into v_p from public.payment_periods where id = p_period_id for update;
  if not found then raise exception '회차 없음: %', p_period_id; end if;
  if v_p.status <> 'open' then
    raise exception '이미 마감된 회차입니다 (현재: %)', v_p.status;
  end if;

  -- 1) 대상 일보 편입 (이미 다른 회차에 든 건 unique index 가 막는다 → 이중청구 방지)
  insert into public.payment_report_link (period_id, report_id)
  select p_period_id, r.id
    from public.daily_reports r
   where r.approval = 'approved'
     and r.date >= v_p.period_from
     and r.date <= v_p.period_to
     and not exists (select 1 from public.payment_report_link l where l.report_id = r.id);
  get diagnostics v_reports = row_count;

  -- 2) 항목별 금회 물량·금액 (재료비/노무비/경비 분할 포함)
  insert into public.payment_lines
    (period_id, contract_id, qty_this, mat_this, labor_this, expense_this, amount_this,
     cum_qty, cum_amount, cum_mat, cum_labor, cum_expense)
  select p_period_id, w.contract_id,
         sum(w.qty),
         round(sum(w.qty) * c.mat_price,     0),
         round(sum(w.qty) * c.labor_price,   0),
         round(sum(w.qty) * c.expense_price, 0),
         round(sum(w.qty) * c.unit_price,    0),
         0,0,0,0,0
    from public.payment_report_link l
    join public.v_billable_work w on w.report_id = l.report_id
    join public.contract_items   c on c.id = w.contract_id
   where l.period_id = p_period_id
     and w.contract_id is not null
   group by w.contract_id, c.mat_price, c.labor_price, c.expense_price, c.unit_price
  on conflict (period_id, contract_id) do update set
     qty_this     = excluded.qty_this,
     mat_this     = excluded.mat_this,
     labor_this   = excluded.labor_this,
     expense_this = excluded.expense_this,
     amount_this  = excluded.amount_this,
     updated_at   = now();
  get diagnostics v_lines = row_count;

  -- 3) 누계 = 이전 회차 합 + 금회
  update public.payment_lines pl set
     cum_qty     = pl.qty_this     + coalesce(prev.qty,0),
     cum_amount  = pl.amount_this  + coalesce(prev.amount,0),
     cum_mat     = pl.mat_this     + coalesce(prev.mat,0),
     cum_labor   = pl.labor_this   + coalesce(prev.labor,0),
     cum_expense = pl.expense_this + coalesce(prev.expense,0),
     updated_at  = now()
    from (
      select p2.contract_id,
             sum(p2.qty_this) qty, sum(p2.amount_this) amount,
             sum(p2.mat_this) mat, sum(p2.labor_this) labor, sum(p2.expense_this) expense
        from public.payment_lines   p2
        join public.payment_periods pp on pp.id = p2.period_id
       where pp.seq_no < v_p.seq_no
       group by p2.contract_id
    ) prev
   where pl.period_id = p_period_id and prev.contract_id = pl.contract_id;

  update public.payment_lines pl set
     cum_qty = pl.qty_this, cum_amount = pl.amount_this,
     cum_mat = pl.mat_this, cum_labor = pl.labor_this, cum_expense = pl.expense_this
   where pl.period_id = p_period_id and pl.cum_amount = 0 and pl.amount_this <> 0;

  -- 4) 미계약 신규항목 건수 (기성 본표에서 빠진 것)
  select count(*) into v_unc
    from public.payment_report_link l
    join public.v_billable_work w on w.report_id = l.report_id
   where l.period_id = p_period_id and w.contract_id is null;

  -- 5) 편입 일보 잠금
  update public.daily_reports set locked = true, updated_at = now()
   where id in (select report_id from public.payment_report_link where period_id = p_period_id);

  -- 6) 회차 마감
  update public.payment_periods
     set status='closed', closed_by=p_actor, closed_at=now(), updated_at=now()
   where id = p_period_id;

  return query select v_reports, v_lines, v_unc;
end $$;


-- ───────────────────────────────────────────────────────────────────
-- 3. reopen_payment_period 도 같은 이유로 계정 비연동으로 교체
-- ───────────────────────────────────────────────────────────────────
drop function if exists public.reopen_payment_period(bigint, text, text);

create or replace function public.reopen_payment_period(
  p_period_id bigint,
  p_reason    text,
  p_actor     text default '공무'
) returns public.payment_periods
language plpgsql
security definer
set search_path = public
as $$
declare v_p public.payment_periods;
begin
  if coalesce(btrim(p_reason),'') = '' then
    raise exception '마감 해제 사유를 입력해야 합니다';
  end if;

  select * into v_p from public.payment_periods where id = p_period_id for update;
  if not found then raise exception '회차 없음: %', p_period_id; end if;
  if v_p.status = 'invoiced' then
    raise exception '이미 청구된 회차는 해제할 수 없습니다';
  end if;

  update public.daily_reports set locked = false, updated_at = now()
   where id in (select report_id from public.payment_report_link where period_id = p_period_id);

  delete from public.payment_report_link where period_id = p_period_id;
  delete from public.payment_lines       where period_id = p_period_id;

  update public.payment_periods
     set status='open', closed_by=null, closed_at=null,
         note = coalesce(note,'') || E'\n[마감해제 ' || to_char(now(),'YYYY-MM-DD HH24:MI')
                || ' / ' || p_actor || '] ' || p_reason,
         updated_at = now()
   where id = p_period_id
  returning * into v_p;

  return v_p;
end $$;


-- ───────────────────────────────────────────────────────────────────
-- 확인
-- ───────────────────────────────────────────────────────────────────
-- select tablename, policyname from pg_policies where schemaname='public'
--   and tablename in ('contract_items','indirect_items','payment_periods','payment_lines','payment_report_link');
-- select seq_no, name, contract_amount from public.indirect_items order by seq_no;
