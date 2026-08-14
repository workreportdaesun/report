-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_INDIRECT_RATE_PRECISION.sql
-- indirect_items.rate 를 9자리로 넓히고 EVERGREEN 요율을 정확히 넣는다
--
-- 작성 2026-08-14
--
-- 【왜 단순 ALTER 가 실패하는가】
--   v_indirect_progress 뷰가 rate 컬럼을 참조하므로 PostgreSQL 이 타입 변경을 거부한다.
--       ERROR: cannot alter type of a column used by a view or rule
--   v_payment_rollup 은 다시 v_indirect_progress 를 참조하므로 둘 다 걸린다.
--   → 뷰를 지우고 → 타입 바꾸고 → 뷰를 다시 만든다. 아래 순서가 그것이다.
--
-- 【왜 9자리가 필요한가】
--   numeric(9,6) 은 소수 6자리가 한계라 공과잡비 요율이 0.064634 로 잘린다.
--   그러면 계약금액 검산이 1,888원 어긋난다. 기성은 발주처와 금액을 대조하는
--   서류라 원 단위가 맞아야 한다. 9자리면 7개 항목 전부 오차 1원 이내다.
--
--   요율 출처: 제7회 기성청구 내역서_R4.xlsx 역산
--     직접노무비 3,597,377,432 / 직접공사비 5,261,512,588 / 건강보험료 133,237,283
-- ═══════════════════════════════════════════════════════════════════

-- 1) 의존 뷰 제거 (아래에서 그대로 다시 만든다)
drop view if exists public.v_payment_rollup;
drop view if exists public.v_indirect_progress;

-- 2) 타입 확장
alter table public.indirect_items
  alter column rate type numeric(12,9);

-- 3) EVERGREEN 실제 요율 (9자리)
update public.indirect_items set rate=0.008000000, basis_label='직접노무비 * 0.8%',    updated_at=now() where name='안전관리비';
update public.indirect_items set rate=0.010100000, basis_label='직접노무비 * 법정요율', updated_at=now() where name='고용보험료';
update public.indirect_items set rate=0.037037338, basis_label='직접노무비 * 법정요율', updated_at=now() where name='건강보험료';
update public.indirect_items set rate=0.047015173, basis_label='직접노무비 * 법정요율', updated_at=now() where name='국민연금보험료';
update public.indirect_items set rate=0.129487030, basis_label='건강보험료 * 법정요율', updated_at=now() where name='노인장기요양보험료';
update public.indirect_items set rate=0.000700000, basis_label='직접공사비 * 법정요율', updated_at=now() where name='건설기계대여대금 지급보증 수수료';
update public.indirect_items set rate=0.064633641, basis_label='직접공사비 * 업체요율', updated_at=now() where name='공과잡비';

-- 4) 뷰 재생성 — 내용은 기존과 동일하다
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
    when 'direct_labor'     then d.cum_labor   * i.rate
    when 'direct_total'     then d.cum_total   * i.rate
    when 'health_insurance' then h.health_base * i.rate
    when 'fixed'            then i.contract_amount
    else 0 end, 0) as cum_amount,
  case when i.contract_amount > 0 then round(
    (case i.basis
      when 'direct_labor'     then d.cum_labor   * i.rate
      when 'direct_total'     then d.cum_total   * i.rate
      when 'health_insurance' then h.health_base * i.rate
      when 'fixed'            then i.contract_amount
      else 0 end) / i.contract_amount * 100, 1) else 0 end as progress_pct
from public.indirect_items i, d, h
where i.active
order by i.seq_no;

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
-- 5) 검산 — 차이 열이 전부 0 또는 ±1 이면 정상
-- ───────────────────────────────────────────────────────────────────
select
  seq_no                        as "순번",
  name                          as "항목",
  basis_label                   as "산출식",
  round(rate*100, 6)            as "요율(%)",
  contract_amount               as "계약금액",
  round(case basis
          when 'direct_labor'     then 3597377432 * rate
          when 'direct_total'     then 5261512588 * rate
          when 'health_insurance' then  133237283 * rate
          else contract_amount end, 0)                    as "검산금액",
  contract_amount - round(case basis
          when 'direct_labor'     then 3597377432 * rate
          when 'direct_total'     then 5261512588 * rate
          when 'health_insurance' then  133237283 * rate
          else contract_amount end, 0)                    as "차이"
from public.indirect_items
order by seq_no;
