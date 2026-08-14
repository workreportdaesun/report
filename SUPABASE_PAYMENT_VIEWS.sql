-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_PAYMENT_VIEWS.sql
-- 집계 뷰 — daily_reports.items(jsonb) 를 행으로 펼치고 계약과 대조한다
--
-- 작성 2026-08-14 / 적용 순서 3번 (CONTRACT_ITEMS, REPORT_APPROVAL 다음)
-- 읽기 전용이라 기존 앱에 영향 없음.
--
-- 【FCN 제외 규칙】 2026-08-14 사용자 확정
--   items[].status 의 '변경전' / '변경후' 는 FCN(설계변경) 건으로
--   물량에 포함하지 않는다. v_daily_work.is_fcn 으로 표시하고
--   집계 뷰에서 제외한다. (원본 뷰에는 남겨두어 이력 조회는 가능)
--
-- 【구역(zone) 매칭】
--   items[].loc 이 곧 작업구역('SCC'|'U&O', app_settings.global.areas).
--   계약항목이 구역 전용이면 그쪽을, 없으면 공통 계약('')을 쓴다.
--   lateral + limit 1 로 한 실적행이 두 계약에 동시에 붙는 것을 막는다.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 뷰 1 : items jsonb 배열을 행 단위로 펼침
--
-- 방어 2가지 — 이 뷰가 에러를 내면 기성·공정률이 전부 멈춘다
--   (a) items 가 배열이 아닌 행(과거 데이터/버그)은 빈 배열로 취급
--   (b) qty 가 숫자 형태가 아니면 캐스트하지 않고 0 처리
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_daily_work as
select
  r.id                                    as report_id,
  r.date                                  as report_date,   -- text 'YYYY-MM-DD'
  r.team,
  r.status                                as doc_status,    -- draft | submitted
  r.approval,                                               -- pending | approved | rejected
  r.locked,
  it->>'menu'                             as menu,
  it->>'cat'                              as cat,
  coalesce(it->>'spec','')                as spec,
  it->>'tag'                              as tag,
  it->>'unit'                             as unit,
  coalesce(it->>'loc','')                 as zone,           -- 'SCC' | 'U&O'
  it->>'status'                           as work_type,      -- 진행 | 완료 | 변경전 | 변경후
  coalesce(it->>'status','') in ('변경전','변경후')  as is_fcn,
  case when (it->>'qty') ~ '^-?[0-9]+(\.[0-9]+)?$'          -- (b)
       then (it->>'qty')::numeric else 0 end  as qty,
  coalesce(it->>'note','')                as note
from public.daily_reports r
cross join lateral jsonb_array_elements(
  case when jsonb_typeof(r.items) = 'array'                  -- (a)
       then r.items else '[]'::jsonb end
) as it;

comment on view public.v_daily_work is
  'daily_reports.items 를 행으로 펼친 원본 뷰. FCN(변경전/변경후) 행도 포함하되 is_fcn 으로 표시.';


-- ───────────────────────────────────────────────────────────────────
-- 뷰 2 : 기성 집계 대상 실적 (승인 + FCN 제외 + 계약항목 매칭)
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_billable_work as
select
  w.report_id, w.report_date, w.team, w.zone,
  w.menu, w.cat, w.spec, w.tag, w.unit, w.work_type, w.qty,
  c.contract_id
from public.v_daily_work w
left join lateral (
  select ci.id as contract_id
  from public.contract_items ci
  where ci.active
    and ci.menu = w.menu
    and ci.cat  = w.cat
    and ci.spec = w.spec
    and (ci.zone = w.zone or ci.zone = '')
  order by (ci.zone = w.zone) desc   -- 구역 전용 계약이 공통 계약보다 우선
  limit 1
) c on true
where w.approval = 'approved'   -- R1 : 승인된 일보만
  and not w.is_fcn;             -- FCN 제외 (2026-08-14 확정)

comment on view public.v_billable_work is
  '기성 집계 대상 실적. 승인 완료 + FCN 제외. contract_id 가 null 이면 미계약 신규항목.';


-- ───────────────────────────────────────────────────────────────────
-- 뷰 3 : 계약 대비 누계 진도율
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_contract_progress as
select
  c.id            as contract_id,
  c.menu, c.cat, c.spec, c.zone, c.unit, c.description, c.wbs, c.sort_no,
  c.contract_qty, c.unit_price, c.contract_amount,
  coalesce(w.cum_qty, 0)                            as cum_qty,
  round(coalesce(w.cum_qty, 0) * c.unit_price, 0)   as cum_amount,
  case when c.contract_qty > 0
       then round(coalesce(w.cum_qty,0) / c.contract_qty * 100, 1)
       else 0 end                                   as progress_pct,
  c.contract_qty - coalesce(w.cum_qty, 0)           as remain_qty,
  round(c.contract_amount - coalesce(w.cum_qty,0) * c.unit_price, 0) as remain_amount,
  (coalesce(w.cum_qty, 0) > c.contract_qty)         as over_contract  -- R3 계약초과 경고
from public.contract_items c
left join (
  select contract_id, sum(qty) as cum_qty
  from public.v_billable_work
  where contract_id is not null
  group by contract_id
) w on w.contract_id = c.id
where c.active;

comment on view public.v_contract_progress is
  '계약 대비 누계 진도율. over_contract = true 면 계약물량 초과(자동으로 자르지 않음).';


-- ───────────────────────────────────────────────────────────────────
-- 뷰 4 : 미계약 신규항목 검출 (R5)
--        계약내역에 없는 실적 — 기성 본표에 넣으면 안 되는 항목
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_uncontracted_work as
select
  w.menu, w.cat, w.spec, w.zone, w.unit,
  count(*)              as line_count,
  sum(w.qty)            as total_qty,
  min(w.report_date)    as first_date,
  max(w.report_date)    as last_date
from public.v_billable_work w
where w.contract_id is null
group by w.menu, w.cat, w.spec, w.zone, w.unit;

comment on view public.v_uncontracted_work is
  '계약내역에 없는 승인 실적. 기성 본표 제외 대상이며 계약 변경 검토가 필요한 목록.';


-- ───────────────────────────────────────────────────────────────────
-- 뷰 5 : FCN(설계변경) 현황 — 물량엔 안 들어가지만 별도 관리 필요
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_fcn_work as
select
  w.report_id, w.report_date, w.team, w.zone,
  w.menu, w.cat, w.spec, w.tag, w.unit, w.work_type, w.qty, w.note
from public.v_daily_work w
where w.is_fcn
  and w.approval = 'approved';

comment on view public.v_fcn_work is
  'FCN(변경전/변경후) 건. 기성 물량에서 제외되며 설계변경 정산은 별도로 처리한다.';


-- ───────────────────────────────────────────────────────────────────
-- 뷰 6 : 전체 공정률 (금액 가중)
-- ───────────────────────────────────────────────────────────────────
create or replace view public.v_project_progress as
select
  sum(contract_amount)                                        as total_contract_amount,
  sum(cum_amount)                                             as total_earned_amount,
  case when sum(contract_amount) > 0
       then round(sum(cum_amount) / sum(contract_amount) * 100, 1)
       else 0 end                                             as overall_progress_pct,
  count(*)                                                    as item_count,
  count(*) filter (where over_contract)                       as over_contract_count
from public.v_contract_progress;

comment on view public.v_project_progress is
  '전체 공정률 = Σ누계기성금액 / Σ계약금액 (금액 가중). 기존 progress 앱의 FACTOR 가중평균과 방식이 다르므로 대조 필요.';
