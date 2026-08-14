-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_PAYMENT_TABLES.sql
-- 기성 회차·내역·이중청구 차단 + 월 마감 RPC
--
-- 작성 2026-08-14 / 적용 순서 4번 (마지막)
-- 선행 필요 : SUPABASE_CONTRACT_ITEMS.sql
--             SUPABASE_REPORT_APPROVAL.sql
--             SUPABASE_PAYMENT_VIEWS.sql
--
-- 【이중청구 방지 설계】
--   payment_report_link.report_id 에 전역 UNIQUE 인덱스를 건다.
--   하나의 일보는 평생 한 회차에만 편입될 수 있고, 두 번 넣으려 하면 DB 가 거부한다.
--   코드 로직이 아니라 제약조건이라 버그나 실수로도 뚫리지 않는다.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. payment_periods : 기성 회차 (마감 단위)
-- ───────────────────────────────────────────────────────────────────
create table if not exists public.payment_periods (
  id                bigserial primary key,
  seq_no            integer not null,             -- 기성 회차 (1, 2, 3 ...)
  period_from       text not null,                -- 'YYYY-MM-DD' (daily_reports.date 가 text 라 맞춤)
  period_to         text not null,
  status            text not null default 'open', -- open | closed | invoiced

  -- 회차 단위 공제 — 실제 계약서 조항으로 채울 것 (기본 0)
  advance_deduction numeric(16,2) not null default 0,   -- 선급금 정산액
  retention_amount  numeric(16,2) not null default 0,   -- 유보금
  other_deduction   numeric(16,2) not null default 0,   -- 기타공제
  vat_rate          numeric(5,4)  not null default 0.10,

  closed_by         text,
  closed_at         timestamptz,
  note              text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint payment_periods_seq_uq   unique (seq_no),
  constraint payment_periods_stat_chk check (status in ('open','closed','invoiced')),
  constraint payment_periods_span_chk check (period_from <= period_to)
);

comment on table public.payment_periods is
  '기성 회차. 공제(선급금·유보금)는 항목이 아니라 회차 단위로 붙으므로 여기에 둔다.';
comment on column public.payment_periods.advance_deduction is
  '선급금 정산액. 계약서 조항 확인 후 입력. 일반적 안분식 = 선급금총액 × (금회기성 ÷ 총계약금액).';


-- ───────────────────────────────────────────────────────────────────
-- 2. payment_lines : 회차별 항목 기성 내역
-- ───────────────────────────────────────────────────────────────────
create table if not exists public.payment_lines (
  id           bigserial primary key,
  period_id    bigint not null references public.payment_periods(id) on delete cascade,
  contract_id  bigint not null references public.contract_items(id),

  qty_this     numeric(14,2) not null default 0,  -- 금회 물량
  amount_this  numeric(16,2) not null default 0,  -- 금회 금액 = 금회물량 × 단가
  cum_qty      numeric(14,2) not null default 0,  -- 누계 물량 (이전 회차 합 + 금회)
  cum_amount   numeric(16,2) not null default 0,  -- 누계 금액

  updated_at   timestamptz not null default now(),

  constraint payment_lines_uq unique (period_id, contract_id)
);

create index if not exists payment_lines_contract_idx
  on public.payment_lines (contract_id);


-- ───────────────────────────────────────────────────────────────────
-- 3. payment_report_link : 회차에 편입된 일보 (이중청구 구조적 차단)
-- ───────────────────────────────────────────────────────────────────
create table if not exists public.payment_report_link (
  period_id  bigint not null references public.payment_periods(id) on delete cascade,
  report_id  text   not null references public.daily_reports(id),
  linked_at  timestamptz not null default now(),
  primary key (period_id, report_id)
);

-- ★ 핵심 : 하나의 일보는 평생 한 회차에만 들어갈 수 있다 (R2)
create unique index if not exists payment_report_link_once
  on public.payment_report_link (report_id);

comment on index public.payment_report_link_once is
  '이중청구 방지. 같은 일보를 두 회차에 편입하려 하면 DB 가 거부한다.';


-- ═══════════════════════════════════════════════════════════════════
-- 4. close_payment_period : 월 마감 처리
--
--   R1  승인된 일보만 집계          → approval='approved' (v_billable_work)
--   R2  이중청구 방지               → payment_report_link unique + not exists
--   FCN 변경전/변경후 제외          → v_billable_work 에서 이미 제외됨
--   S5-7 마감 잠금                  → daily_reports.locked = true
-- ═══════════════════════════════════════════════════════════════════
create or replace function public.close_payment_period(
  p_period_id bigint,
  p_actor_id  text                     -- members.id
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
  -- 1) 권한 확인 (마감은 admin 만)
  select role, name into v_role, v_name from public.members where id = p_actor_id;
  if not found then
    raise exception '등록되지 않은 사용자입니다: %', p_actor_id;
  end if;
  if coalesce(v_role,'worker') <> 'admin' then
    raise exception '기성 마감 권한이 없습니다 (현재 등급: %)', coalesce(v_role,'worker');
  end if;

  -- 2) 회차 잠금
  select * into v_p from public.payment_periods where id = p_period_id for update;
  if not found then
    raise exception '회차 없음: %', p_period_id;
  end if;
  if v_p.status <> 'open' then
    raise exception '이미 마감된 회차입니다 (현재: %)', v_p.status;
  end if;

  -- 3) 대상 일보를 회차에 편입
  --    이미 다른 회차에 들어간 일보는 not exists 로 걸러지고,
  --    혹시 통과해도 payment_report_link_once 유니크가 막는다
  insert into public.payment_report_link (period_id, report_id)
  select p_period_id, r.id
    from public.daily_reports r
   where r.approval = 'approved'
     and r.date >= v_p.period_from
     and r.date <= v_p.period_to
     and not exists (
       select 1 from public.payment_report_link l where l.report_id = r.id
     );
  get diagnostics v_reports = row_count;

  -- 4) 항목별 금회 물량·금액 집계
  insert into public.payment_lines (period_id, contract_id, qty_this, amount_this, cum_qty, cum_amount)
  select p_period_id,
         w.contract_id,
         sum(w.qty),
         round(sum(w.qty) * c.unit_price, 0),
         0, 0
    from public.payment_report_link l
    join public.v_billable_work w on w.report_id = l.report_id
    join public.contract_items   c on c.id = w.contract_id
   where l.period_id = p_period_id
     and w.contract_id is not null
   group by w.contract_id, c.unit_price
  on conflict (period_id, contract_id) do update set
     qty_this    = excluded.qty_this,
     amount_this = excluded.amount_this,
     updated_at  = now();
  get diagnostics v_lines = row_count;

  -- 5) 누계 = 이전 회차(seq_no 가 작은)까지의 합 + 금회
  update public.payment_lines pl set
     cum_qty = pl.qty_this + coalesce((
       select sum(p2.qty_this)
         from public.payment_lines   p2
         join public.payment_periods pp on pp.id = p2.period_id
        where p2.contract_id = pl.contract_id
          and pp.seq_no < v_p.seq_no), 0),
     cum_amount = pl.amount_this + coalesce((
       select sum(p2.amount_this)
         from public.payment_lines   p2
         join public.payment_periods pp on pp.id = p2.period_id
        where p2.contract_id = pl.contract_id
          and pp.seq_no < v_p.seq_no), 0),
     updated_at = now()
   where pl.period_id = p_period_id;

  -- 6) 미계약 신규항목 건수 (기성 본표에서 빠진 것 — 보고용)
  select count(*) into v_unc
    from public.payment_report_link l
    join public.v_billable_work w on w.report_id = l.report_id
   where l.period_id = p_period_id
     and w.contract_id is null;

  -- 7) 편입된 일보를 잠근다 (마감 후 수정 차단)
  update public.daily_reports set locked = true, updated_at = now()
   where id in (select report_id from public.payment_report_link where period_id = p_period_id);

  -- 8) 회차 마감
  update public.payment_periods
     set status    = 'closed',
         closed_by = v_name,
         closed_at = now(),
         updated_at= now()
   where id = p_period_id;

  return query select v_reports, v_lines, v_unc;
end $$;

comment on function public.close_payment_period is
  '기성 회차 마감. admin 만 실행 가능. 승인 일보 편입 → 항목 집계 → 누계 계산 → 일보 잠금 → 회차 마감.';


-- ═══════════════════════════════════════════════════════════════════
-- 5. reopen_payment_period : 마감 해제 (사유 필수, admin 만)
-- ═══════════════════════════════════════════════════════════════════
create or replace function public.reopen_payment_period(
  p_period_id bigint,
  p_actor_id  text,
  p_reason    text
) returns public.payment_periods
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p    public.payment_periods;
  v_role text;
  v_name text;
begin
  if coalesce(btrim(p_reason),'') = '' then
    raise exception '마감 해제 사유를 입력해야 합니다';
  end if;

  select role, name into v_role, v_name from public.members where id = p_actor_id;
  if not found then raise exception '등록되지 않은 사용자입니다: %', p_actor_id; end if;
  if coalesce(v_role,'worker') <> 'admin' then
    raise exception '마감 해제 권한이 없습니다 (현재 등급: %)', coalesce(v_role,'worker');
  end if;

  select * into v_p from public.payment_periods where id = p_period_id for update;
  if not found then raise exception '회차 없음: %', p_period_id; end if;
  if v_p.status = 'invoiced' then
    raise exception '이미 청구된 회차는 해제할 수 없습니다';
  end if;

  -- 편입 해제 + 일보 잠금 해제
  update public.daily_reports set locked = false, updated_at = now()
   where id in (select report_id from public.payment_report_link where period_id = p_period_id);

  delete from public.payment_report_link where period_id = p_period_id;
  delete from public.payment_lines       where period_id = p_period_id;

  update public.payment_periods
     set status    = 'open',
         closed_by = null,
         closed_at = null,
         note      = coalesce(note,'') || E'\n[마감해제 ' || to_char(now(),'YYYY-MM-DD HH24:MI')
                     || ' / ' || v_name || '] ' || p_reason,
         updated_at= now()
   where id = p_period_id
  returning * into v_p;

  return v_p;
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- 6. 기성 청구 요약 뷰 (PART 2-5 청구요약서)
-- ═══════════════════════════════════════════════════════════════════
create or replace view public.v_payment_summary as
select
  p.id            as period_id,
  p.seq_no,
  p.period_from,
  p.period_to,
  p.status,
  coalesce(sum(l.amount_this), 0)                     as amount_this,
  coalesce(sum(l.cum_amount),  0)                     as cum_amount,
  p.advance_deduction,
  p.retention_amount,
  p.other_deduction,
  (p.advance_deduction + p.retention_amount + p.other_deduction)          as deduction_total,
  coalesce(sum(l.amount_this), 0)
    - (p.advance_deduction + p.retention_amount + p.other_deduction)      as claim_amount,
  round((coalesce(sum(l.amount_this), 0)
    - (p.advance_deduction + p.retention_amount + p.other_deduction))
    * p.vat_rate, 0)                                                     as vat_amount,
  round((coalesce(sum(l.amount_this), 0)
    - (p.advance_deduction + p.retention_amount + p.other_deduction))
    * (1 + p.vat_rate), 0)                                               as total_claim_amount
from public.payment_periods p
left join public.payment_lines l on l.period_id = p.id
group by p.id;

comment on view public.v_payment_summary is
  '회차별 청구 요약. 금회기성 - 공제계 = 청구액, + VAT = 최종청구금액.';


-- ───────────────────────────────────────────────────────────────────
-- 사용 예시
-- ───────────────────────────────────────────────────────────────────
-- -- 1) 8월 회차 생성
-- insert into public.payment_periods (seq_no, period_from, period_to)
-- values (1, '2026-08-01', '2026-08-31');
--
-- -- 2) 마감 실행 (p_actor_id 는 members.id)
-- select * from public.close_payment_period(1, '<admin members.id>');
--
-- -- 3) 결과 확인
-- select * from public.v_payment_summary where seq_no = 1;
-- select * from public.v_contract_progress order by sort_no;
-- select * from public.v_uncontracted_work;   -- 기성에서 빠진 미계약 항목
-- select * from public.v_fcn_work;            -- 물량 제외된 FCN 건
