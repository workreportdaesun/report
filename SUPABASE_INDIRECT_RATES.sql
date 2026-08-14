-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_INDIRECT_RATES.sql
-- 간접공사비 요율 — EVERGREEN 기준으로 설정
--
-- 작성 2026-08-14
--
-- 【요율 출처 — 추측 없이 실제 기성서류에서 역산】
--   근거: C:\Users\windows\Desktop\공유\03) 7회 기성\제7회 기성청구 내역서_R4.xlsx
--         "4. 내역서" 7행 A.직접공사비
--             재료비 1,664,135,156 / 노무비 3,597,377,432 / 경비 0
--             합계   5,261,512,588
--         "3. 집계표" B.간접공사비 각 항목 계약금액 ÷ 위 기준액
--
--   요율은 소수 9자리까지 쓴다. 6자리로 끊으면 공과잡비에서 1,888원이 어긋나는데,
--   기성은 발주처와 금액을 대조하는 서류라 원 단위가 맞아야 한다.
--   9자리로 두면 7개 항목 전부 오차 1원 이내다.
-- ═══════════════════════════════════════════════════════════════════

-- rate 컬럼을 9자리까지 받도록 넓힌다 (기존 numeric(9,6) → 6자리가 한계였음)
alter table public.indirect_items
  alter column rate type numeric(12,9);


-- ───────────────────────────────────────────────────────────────────
-- EVERGREEN 실제 요율
--
--   항목                          요율          기준         검산(요율×기준)   원본금액
--   안전관리비                0.008000000   직접노무비      28,779,019    28,779,019
--   고용보험료                0.010100000   직접노무비      36,333,512    36,333,512
--   건강보험료                0.037037338   직접노무비     133,237,284   133,237,283
--   국민연금보험료             0.047015173   직접노무비     169,131,322   169,131,322
--   노인장기요양보험료          0.129487030   건강보험료      17,252,500    17,252,500
--   건설기계대여대금 지급보증    0.000700000   직접공사비       3,683,059     3,683,059
--   공과잡비                 0.064633641   직접공사비     340,070,716   340,070,717
-- ───────────────────────────────────────────────────────────────────
update public.indirect_items set rate=0.008000000, basis_label='직접노무비 * 0.8%',      updated_at=now() where name='안전관리비';
update public.indirect_items set rate=0.010100000, basis_label='직접노무비 * 법정요율',   updated_at=now() where name='고용보험료';
update public.indirect_items set rate=0.037037338, basis_label='직접노무비 * 법정요율',   updated_at=now() where name='건강보험료';
update public.indirect_items set rate=0.047015173, basis_label='직접노무비 * 법정요율',   updated_at=now() where name='국민연금보험료';
update public.indirect_items set rate=0.129487030, basis_label='건강보험료 * 법정요율',   updated_at=now() where name='노인장기요양보험료';
update public.indirect_items set rate=0.000700000, basis_label='직접공사비 * 법정요율',   updated_at=now() where name='건설기계대여대금 지급보증 수수료';
update public.indirect_items set rate=0.064633641, basis_label='직접공사비 * 업체요율',   updated_at=now() where name='공과잡비';


-- ═══════════════════════════════════════════════════════════════════
-- 간접비 계약금액 재산출 함수
--
--   계약금액 = 계약 기준액 × 요율
--     direct_labor     → Σ(contract_qty × labor_price)
--     direct_total     → Σ(contract_amount)
--     health_insurance → 건강보험료 계약금액 (1단계가 끝난 뒤 계산해야 함)
--
--   지금 contract_amount 에는 EVERGREEN 제7회 값이 그대로 들어 있고 요율과도 일치한다.
--   나중에 다른 현장의 계약내역을 올리면 이 함수로 다시 잡으면 된다.
--   계약내역이 비어 있을 때 실행하면 기준액이 0이라 전부 0이 되므로 오류로 막았다.
-- ═══════════════════════════════════════════════════════════════════
create or replace function public.refresh_indirect_contract_amounts()
returns table (name text, basis text, rate numeric, contract_amount numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_labor  numeric;
  v_total  numeric;
  v_health numeric;
begin
  select coalesce(sum(c.contract_qty * c.labor_price), 0),
         coalesce(sum(c.contract_amount), 0)
    into v_labor, v_total
    from public.contract_items c
   where c.active;

  if v_total = 0 then
    raise exception '계약내역(contract_items)이 비어 있습니다. 계약내역을 먼저 업로드하세요.';
  end if;

  update public.indirect_items i
     set contract_amount = round(
           case i.basis
             when 'direct_labor' then v_labor * i.rate
             when 'direct_total' then v_total * i.rate
             else i.contract_amount
           end, 0),
         updated_at = now()
   where i.active and i.basis in ('direct_labor','direct_total');

  -- 노인장기요양은 건강보험료가 확정된 뒤에 계산한다
  select i.contract_amount into v_health
    from public.indirect_items i
   where i.active and i.name = '건강보험료'
   limit 1;

  update public.indirect_items i
     set contract_amount = round(coalesce(v_health,0) * i.rate, 0),
         updated_at = now()
   where i.active and i.basis = 'health_insurance';

  return query
    select i.name, i.basis, i.rate, i.contract_amount
      from public.indirect_items i
     where i.active
     order by i.seq_no;
end $$;

comment on function public.refresh_indirect_contract_amounts is
  '간접비 계약금액을 계약내역(contract_items) 기준으로 다시 계산한다. 다른 현장 계약내역을 올렸을 때 실행할 것.';


-- ───────────────────────────────────────────────────────────────────
-- 확인 — 요율과 계약금액이 서로 맞는지 검산까지 같이 본다
--   기준액: 직접노무비 3,597,377,432 / 직접공사비 5,261,512,588 (EVERGREEN 제7회)
-- ───────────────────────────────────────────────────────────────────
select
  seq_no                                   as "순번",
  name                                     as "항목",
  basis_label                              as "산출식",
  round(rate * 100, 6)                     as "요율(%)",
  contract_amount                          as "계약금액",
  round(
    case basis
      when 'direct_labor'     then 3597377432 * rate
      when 'direct_total'     then 5261512588 * rate
      when 'health_insurance' then  133237283 * rate
      else contract_amount
    end, 0)                                as "검산금액",
  contract_amount - round(
    case basis
      when 'direct_labor'     then 3597377432 * rate
      when 'direct_total'     then 5261512588 * rate
      when 'health_insurance' then  133237283 * rate
      else contract_amount
    end, 0)                                as "차이"
from public.indirect_items
order by seq_no;

-- 회차별 간접비 누계는 이 뷰에서 본다 (계약내역·기성 실적이 들어온 뒤)
--   select * from public.v_indirect_progress;
