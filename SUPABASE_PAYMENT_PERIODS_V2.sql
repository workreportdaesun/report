-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_PAYMENT_PERIODS_V2.sql
-- 회차별 기성 누적 — 단가 3분할 저장 + 열린 회차 실시간 집계
--
-- 작성 2026-08-14 / 적용 순서 6번 (기존 5종 실행 후)
-- 근거 : 제7회 기성청구 내역서_R4.xlsx "4. 내역서"
--        회차마다 9열(Q'ty + Material/Labor/Expense/Total 각 U/P·Amount)이 붙는 구조
--
-- 【해결하는 문제 2가지】
--  (1) payment_lines 가 총액만 저장해서 회차별 간접비를 산출할 수 없었다.
--      간접공사비(안전관리비·고용보험·건강보험·국민연금 등)는 전부
--      "그 회차의 직접노무비 × 요율"이라 노무비를 회차별로 들고 있어야 한다.
--      집계표 실제값 : 안전관리비 5회 1,539,000 / 6회 4,818,000 / 7회 4,143,000
--
--  (2) close_payment_period() 가 마감할 때만 payment_lines 를 쓰므로
--      마감 전에는 금회기성이 0으로 보였다. 실무에선 마감 전에 계속 봐야 한다.
--      → 열린 회차는 승인 일보에서 실시간 집계, 마감 회차는 확정값을 그대로 쓴다.
--        (마감 회차를 재계산하면 나중에 단가가 바뀔 때 과거 청구액이 소급 변경된다)
--
-- 【회차 기간】 월 단위 (2026-08-14 사용자 확정)
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. payment_lines 단가 3분할 추가
--    amount_this / cum_amount 는 그대로 두므로 기존 뷰·RPC 가 안 깨진다
-- ───────────────────────────────────────────────────────────────────
alter table public.payment_lines
  add column if not exists mat_this     numeric(16,2) not null default 0,
  add column if not exists labor_this   numeric(16,2) not null default 0,
  add column if not exists expense_this numeric(16,2) not null default 0,
  add column if not exists cum_mat      numeric(16,2) not null default 0,
  add column if not exists cum_labor    numeric(16,2) not null default 0,
  add column if not exists cum_expense  numeric(16,2) not null default 0;

comment on column public.payment_lines.labor_this is
  '금회 노무비. 회차별 간접공사비(직접노무비 × 요율)의 산출 기준.';


-- ───────────────────────────────────────────────────────────────────
-- 2. 월 단위 회차 생성 헬퍼
--    seq_no 는 자동으로 다음 번호를 매긴다
-- ───────────────────────────────────────────────────────────────────
create or replace function public.create_monthly_period(
  p_year  integer,
  p_month integer
) returns public.payment_periods
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from date := make_date(p_year, p_month, 1);
  v_to   date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;
  v_seq  integer;
  v_row  public.payment_periods;
begin
  -- 같은 기간이 이미 있으면 그걸 돌려준다
  select * into v_row from public.payment_periods
   where period_from = to_char(v_from,'YYYY-MM-DD')
     and period_to   = to_char(v_to,'YYYY-MM-DD');
  if found then return v_row; end if;

  select coalesce(max(seq_no),0) + 1 into v_seq from public.payment_periods;

  insert into public.payment_periods (seq_no, period_from, period_to, status)
  values (v_seq, to_char(v_from,'YYYY-MM-DD'), to_char(v_to,'YYYY-MM-DD'), 'open')
  returning * into v_row;

  return v_row;
end $$;

comment on function public.create_monthly_period is
  '월 단위 기성 회차 생성. 같은 기간이 이미 있으면 새로 만들지 않고 기존 회차를 반환한다.';


-- ───────────────────────────────────────────────────────────────────
-- 3. 회차별 기성 (롱포맷) — 화면에서 seq_no 를 열로 피벗한다
--
--    마감 회차(closed/invoiced) : payment_lines 확정값
--    열린 회차(open)            : v_billable_work 실시간 집계
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_payment_by_period as
-- (a) 마감된 회차 — 저장된 확정값을 그대로. 재계산하지 않는다.
select
  p.id        as period_id,
  p.seq_no,
  p.status,
  p.period_from,
  p.period_to,
  l.contract_id,
  l.qty_this,
  l.mat_this,
  l.labor_this,
  l.expense_this,
  l.amount_this
from public.payment_lines l
join public.payment_periods p on p.id = l.period_id
where p.status <> 'open'

union all

-- (b) 열린 회차 — 승인 일보에서 실시간 계산
select
  p.id,
  p.seq_no,
  p.status,
  p.period_from,
  p.period_to,
  w.contract_id,
  sum(w.qty),
  round(sum(w.qty) * c.mat_price,     0),
  round(sum(w.qty) * c.labor_price,   0),
  round(sum(w.qty) * c.expense_price, 0),
  round(sum(w.qty) * c.unit_price,    0)
from public.payment_periods p
join public.v_billable_work w
  on w.report_date >= p.period_from
 and w.report_date <= p.period_to
join public.contract_items c on c.id = w.contract_id
where p.status = 'open'
  and w.contract_id is not null
group by p.id, p.seq_no, p.status, p.period_from, p.period_to, w.contract_id,
         c.mat_price, c.labor_price, c.expense_price, c.unit_price;

comment on view public.v_payment_by_period is
  '회차별 기성 롱포맷. 마감 회차는 확정값, 열린 회차는 실시간 집계. 화면에서 seq_no 로 피벗한다.';


-- ───────────────────────────────────────────────────────────────────
-- 4. 항목 × 회차 요약 — 전회누계 / 금회 / 누계 / 잔여
--    p_seq_no 를 기준 회차로 삼는다
-- ───────────────────────────────────────────────────────────────────
create or replace function public.payment_summary_at(p_seq_no integer)
returns table (
  contract_id   bigint,
  discipline    text,
  cat           text,
  description   text,
  spec          text,
  zone          text,
  unit          text,
  contract_qty  numeric,
  unit_price    numeric,
  mat_price     numeric,
  labor_price   numeric,
  expense_price numeric,
  contract_amount numeric,
  prev_qty      numeric,   -- 전회누계
  prev_amount   numeric,
  this_qty      numeric,   -- 금회
  this_amount   numeric,
  this_labor    numeric,
  cum_qty       numeric,   -- 누계
  cum_amount    numeric,
  progress_pct  numeric,
  remain_qty    numeric,
  remain_amount numeric
)
language sql stable as $$
  select
    c.id, c.discipline, c.cat, c.description, c.spec, c.zone, c.unit,
    c.contract_qty, c.unit_price, c.mat_price, c.labor_price, c.expense_price,
    c.contract_amount,
    coalesce(pv.qty,0), coalesce(pv.amount,0),
    coalesce(th.qty,0), coalesce(th.amount,0), coalesce(th.labor,0),
    coalesce(pv.qty,0) + coalesce(th.qty,0),
    coalesce(pv.amount,0) + coalesce(th.amount,0),
    case when c.contract_amount > 0
         then round((coalesce(pv.amount,0)+coalesce(th.amount,0)) / c.contract_amount * 100, 1)
         else 0 end,
    c.contract_qty   - (coalesce(pv.qty,0) + coalesce(th.qty,0)),
    c.contract_amount - (coalesce(pv.amount,0) + coalesce(th.amount,0))
  from public.contract_items c
  left join lateral (
    select sum(qty_this) as qty, sum(amount_this) as amount
    from public.v_payment_by_period v
    where v.contract_id = c.id and v.seq_no < p_seq_no
  ) pv on true
  left join lateral (
    select sum(qty_this) as qty, sum(amount_this) as amount, sum(labor_this) as labor
    from public.v_payment_by_period v
    where v.contract_id = c.id and v.seq_no = p_seq_no
  ) th on true
  where c.active
  order by c.sort_no, c.id;
$$;


-- ───────────────────────────────────────────────────────────────────
-- 5. close_payment_period 갱신 — 3분할도 같이 확정 저장
-- ───────────────────────────────────────────────────────────────────
create or replace function public.close_payment_period(
  p_period_id bigint,
  p_actor_id  text
) returns table (linked_reports integer, billed_lines integer, uncontracted integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p       public.payment_periods;
  v_role    text;
  v_name    text;
  v_reports integer;
  v_lines   integer;
  v_unc     integer;
begin
  select role, name into v_role, v_name from public.members where id = p_actor_id;
  if not found then raise exception '등록되지 않은 사용자입니다: %', p_actor_id; end if;
  if coalesce(v_role,'worker') <> 'admin' then
    raise exception '기성 마감 권한이 없습니다 (현재 등급: %)', coalesce(v_role,'worker');
  end if;

  select * into v_p from public.payment_periods where id = p_period_id for update;
  if not found then raise exception '회차 없음: %', p_period_id; end if;
  if v_p.status <> 'open' then
    raise exception '이미 마감된 회차입니다 (현재: %)', v_p.status;
  end if;

  -- 1) 대상 일보 편입 (이미 다른 회차에 든 건 unique index 가 막는다 → R2)
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
   where pl.period_id = p_period_id
     and prev.contract_id = pl.contract_id;

  -- 이전 회차 실적이 없는 항목은 누계 = 금회
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
     set status='closed', closed_by=v_name, closed_at=now(), updated_at=now()
   where id = p_period_id;

  return query select v_reports, v_lines, v_unc;
end $$;


-- ───────────────────────────────────────────────────────────────────
-- 확인
-- ───────────────────────────────────────────────────────────────────
-- select * from public.create_monthly_period(2026, 8);
-- select * from public.v_payment_by_period order by seq_no, contract_id;
-- select * from public.payment_summary_at(1);
