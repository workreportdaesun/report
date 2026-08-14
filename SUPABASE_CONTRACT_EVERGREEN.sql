-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_CONTRACT_EVERGREEN.sql
-- 계약내역 구조를 실제 기성내역서(EVERGREEN 기준)에 맞춰 보강
--
-- 작성 2026-08-14 / 적용 순서 5번 (기존 4종 실행 후)
-- 근거 : C:\Users\windows\Desktop\공유\03) 7회 기성\제7회 기성청구 내역서_R4.xlsx
--        H&G EVERGREEN PROJECT · 계장공사 · 대선이엔씨(주) → 한화오션(주)
--
-- 【왜 필요한가】
--   실제 기성내역서는 단가를 재료비/노무비/경비로 나눠서 관리한다.
--   단순 표기 차이가 아니라, 간접공사비 7종이 전부 "직접노무비 × 요율"로
--   산출되기 때문에 노무비를 따로 들고 있지 않으면 간접비를 계산할 수 없다.
--   간접비는 계약금액의 12.2%(728,487,412 / 5,990,000,000)라 무시할 수 없다.
--
--   기존 unit_price 는 3개 합계로 계속 유지한다 → 이미 만든 뷰·마감 RPC를
--   한 줄도 고치지 않아도 된다.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. contract_items 보강
-- ───────────────────────────────────────────────────────────────────
alter table public.contract_items
  -- 단가 3분할 (기성내역서 Material Cost / Labor Cost / Expense)
  add column if not exists mat_price     numeric(14,2) not null default 0,
  add column if not exists labor_price   numeric(14,2) not null default 0,
  add column if not exists expense_price numeric(14,2) not null default 0,
  -- 계층 (기성내역서 A. → (1) → (1.1) → (1.1.4) → 항목행)
  add column if not exists group1        text,     -- 'A. 직접공사비'
  add column if not exists discipline    text,     -- '(3) Instrument Duct & Tray' 공종
  add column if not exists item_no       text,     -- '(1.1.4)' 원본 항목번호
  -- 공종 단위 총액계약(LOT/식) 표시
  add column if not exists is_lot        boolean not null default false,
  -- 지급자재(By Vendor) 등 비고
  add column if not exists remark        text;

comment on column public.contract_items.unit_price is
  '합계단가 = mat_price + labor_price + expense_price. 업로드 시 자동 계산해서 넣는다.';
comment on column public.contract_items.labor_price is
  '노무비 단가. 간접공사비(안전관리비·고용보험·건강보험·국민연금 등)의 산출 기준이 되므로 반드시 분리해서 보관한다.';
comment on column public.contract_items.discipline is
  '기성집계표의 공종. EVERGREEN 기준 10개(Field Instrument, Instrument Cables, ...).';
comment on column public.contract_items.is_lot is
  'true 면 수량 개념 없는 총액계약(LOT/식). 진도율을 물량이 아닌 금액으로만 본다.';

create index if not exists contract_items_disc_idx
  on public.contract_items (discipline) where active;

-- 합계단가 정합성 — 업로드가 잘못 채우면 여기서 걸린다
alter table public.contract_items
  drop constraint if exists contract_items_price_chk;
alter table public.contract_items
  add constraint contract_items_price_chk
  check (abs(unit_price - (mat_price + labor_price + expense_price)) < 0.005);


-- ───────────────────────────────────────────────────────────────────
-- 2. indirect_items : 간접공사비 (요율 기반)
--
--    EVERGREEN 제7회 기준 실제 값
--      안전관리비                        직접노무비 × 0.8%      28,779,019
--      고용보험료                        직접노무비 × 법정요율   36,333,512
--      건강보험료                        직접노무비 × 법정요율  133,237,283
--      국민연금보험료                    직접노무비 × 법정요율  169,131,322
--      노인장기요양보험료                건강보험료  × 법정요율   17,252,500
--      건설기계대여대금 지급보증 수수료  직접공사비 × 법정요율    3,683,059
--      공과잡비                          직접공사비 × 업체요율  340,070,717
--                                                     계      728,487,412
-- ───────────────────────────────────────────────────────────────────
create table if not exists public.indirect_items (
  id              bigserial primary key,
  seq_no          integer not null,
  name            text not null,                  -- '안전관리비'
  basis           text not null,                  -- 산출 기준 (아래 check 참고)
  basis_label     text,                           -- '직접노무비 * 0.8%' 원문 표기
  rate            numeric(9,6) not null default 0,
  contract_amount numeric(16,2) not null default 0,
  active          boolean not null default true,
  note            text,
  updated_at      timestamptz not null default now(),
  constraint indirect_items_seq_uq unique (seq_no),
  constraint indirect_items_basis_chk check (basis in (
    'direct_labor',       -- 직접노무비 기준
    'direct_total',       -- 직접공사비 기준
    'health_insurance',   -- 건강보험료 기준 (노인장기요양)
    'fixed'               -- 고정금액
  ))
);

comment on table public.indirect_items is
  '간접공사비. 직접공사비/직접노무비에 요율을 곱해 산출하며 기성집계표 B항에 해당한다.';


-- ───────────────────────────────────────────────────────────────────
-- 3. 뷰 : 직접공사비 재료비/노무비 분해 (간접비 산출의 기준)
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_direct_cost_split as
select
  sum(p.cum_qty * c.mat_price)     as cum_material,
  sum(p.cum_qty * c.labor_price)   as cum_labor,      -- ★ 간접비 산출 기준
  sum(p.cum_qty * c.expense_price) as cum_expense,
  sum(p.cum_amount)                as cum_total,
  sum(c.contract_qty * c.mat_price)     as contract_material,
  sum(c.contract_qty * c.labor_price)   as contract_labor,
  sum(c.contract_qty * c.expense_price) as contract_expense,
  sum(c.contract_amount)                as contract_total
from public.contract_items c
join public.v_contract_progress p on p.contract_id = c.id
where c.active;

comment on view public.v_direct_cost_split is
  '직접공사비를 재료비·노무비·경비로 분해. cum_labor 가 간접공사비 산출의 기준이 된다.';


-- ───────────────────────────────────────────────────────────────────
-- 4. 뷰 : 간접공사비 누계 산출
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_indirect_progress as
with d as (select * from public.v_direct_cost_split),
     h as (
       select coalesce(sum(
         case when i.basis='direct_labor' then d.cum_labor * i.rate else 0 end
       ),0) as health_base
       from public.indirect_items i, d
       where i.active and i.name like '%건강보험%'
     )
select
  i.seq_no, i.name, i.basis, i.basis_label, i.rate, i.contract_amount,
  round(case i.basis
    when 'direct_labor'     then d.cum_labor  * i.rate
    when 'direct_total'     then d.cum_total  * i.rate
    when 'health_insurance' then h.health_base * i.rate
    when 'fixed'            then i.contract_amount
    else 0 end, 0) as cum_amount,
  case when i.contract_amount > 0 then round(
    (case i.basis
      when 'direct_labor'     then d.cum_labor  * i.rate
      when 'direct_total'     then d.cum_total  * i.rate
      when 'health_insurance' then h.health_base * i.rate
      when 'fixed'            then i.contract_amount
      else 0 end) / i.contract_amount * 100, 1) else 0 end as progress_pct
from public.indirect_items i, d, h
where i.active
order by i.seq_no;


-- ───────────────────────────────────────────────────────────────────
-- 5. 뷰 : 기성 집계표 (직접 + 간접 = 총 계약금액)
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_payment_rollup as
select 'A. 직접공사비' as section, null::integer as seq_no, '직접공사비 계' as name,
       sum(contract_amount) as contract_amount, sum(cum_amount) as cum_amount,
       case when sum(contract_amount)>0
            then round(sum(cum_amount)/sum(contract_amount)*100,1) else 0 end as progress_pct
from public.v_contract_progress
union all
select 'B. 간접공사비', seq_no, name, contract_amount, cum_amount, progress_pct
from public.v_indirect_progress;


-- ───────────────────────────────────────────────────────────────────
-- 6. EVERGREEN 간접공사비 초기값 (실제 요율로 교체할 것)
--    집계표에 요율이 잘려 있어 계약금액만 넣어두고 rate 는 0으로 둔다.
--    rate 를 채우면 v_indirect_progress 가 누계를 자동 산출한다.
-- ───────────────────────────────────────────────────────────────────
insert into public.indirect_items (seq_no, name, basis, basis_label, rate, contract_amount) values
  (1,'안전관리비',                      'direct_labor',    '직접노무비 * 0.8%',      0.008,  28779019),
  (2,'고용보험료',                      'direct_labor',    '직접노무비 * 법정요율',   0,      36333512),
  (3,'건강보험료',                      'direct_labor',    '직접노무비 * 법정요율',   0,     133237283),
  (4,'국민연금보험료',                  'direct_labor',    '직접노무비 * 법정요율',   0,     169131322),
  (5,'노인장기요양보험료',              'health_insurance','건강보험료 * 법정요율',   0,      17252500),
  (6,'건설기계대여대금 지급보증 수수료','direct_total',    '직접공사비 * 법정요율',   0,       3683059),
  (7,'공과잡비',                        'direct_total',    '직접공사비 * 업체요율',   0,     340070717)
on conflict (seq_no) do nothing;


-- ───────────────────────────────────────────────────────────────────
-- 확인
-- ───────────────────────────────────────────────────────────────────
-- select * from public.v_direct_cost_split;
-- select * from public.v_indirect_progress;
-- select * from public.v_payment_rollup;
