-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_기성계층_ALL.sql  —  통합 실행 스크립트 (2026-08-14)
--
-- Supabase SQL Editor 에 전체를 붙여넣고 한 번에 Run 하면 된다.
-- 개별 파일(CONTRACT_ITEMS/REPORT_APPROVAL/PAYMENT_VIEWS/PAYMENT_TABLES)을
-- 이 순서대로 이어붙인 것이며 내용은 동일하다.
--
-- 실행 후 확인:
--   select approval, status, count(*) from public.daily_reports group by 1,2;
--   select * from public.v_project_progress;
-- ═══════════════════════════════════════════════════════════════════


-- ###################################################################
-- ##  SUPABASE_CONTRACT_ITEMS.sql
-- ###################################################################

-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_CONTRACT_ITEMS.sql
-- 계약내역 마스터 — 기성 산출의 분모(계약수량)와 단가의 출처
--
-- 작성 2026-08-14 / 적용 순서 1번 (다른 기성 SQL보다 먼저 실행)
-- 신규 테이블이라 기존 8개 앱에 영향 없음.
--
-- 【키 설계】 (menu, cat, spec, zone)
--   - menu/cat/spec 은 daily_reports.items[] 의 같은 이름 필드와 글자까지 일치해야 조인됨
--   - zone 은 items[].loc 값('SCC'|'U&O')과 대응. 빈 문자열('')이면 전 구역 공통 계약
--   - plan_items 와는 grain 이 다르므로 합치지 않는다
--       plan_items      : (cat, tag, spec)      TAG 단위 계획/설치 수량
--       contract_items  : (menu, cat, spec, zone) 항목 단위 계약수량·단가
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.contract_items (
  id              bigserial primary key,

  -- 조인 키 (items[] 와 어휘 일치 필수)
  menu            text not null,                  -- 공종 대분류
  cat             text not null,                  -- 작업분류
  spec            text not null default '',       -- 규격 (없으면 '' — NULL 금지)
  zone            text not null default '',       -- 'SCC' | 'U&O' | '' = 전구역 공통

  -- 계약 내용
  description     text,                           -- 품명 (기성내역서 출력용)
  unit            text not null,                  -- 단위 (app_settings.global.item_unit 과 일치시킬 것)
  contract_qty    numeric(14,2) not null default 0,
  unit_price      numeric(14,2) not null default 0,
  contract_amount numeric(16,2)
                  generated always as (contract_qty * unit_price) stored,

  wbs             text,
  sort_no         integer not null default 0,     -- 기성내역서 출력 순서
  active          boolean not null default true,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- 같은 (공종,분류,규격,구역)이 두 줄 생기면 기성이 이중 집계된다
create unique index if not exists contract_items_key
  on public.contract_items (menu, cat, spec, zone);

create index if not exists contract_items_cat_idx
  on public.contract_items (cat) where active;

comment on table  public.contract_items is
  '계약내역 마스터. 기성 산출의 계약수량·단가 출처. 실적은 daily_reports.items[] 에서 온다.';
comment on column public.contract_items.zone is
  'items[].loc 과 대응. ''''(빈문자열)이면 전 구역 공통 계약. 구역 전용 행이 있으면 그쪽이 우선 매칭된다.';
comment on column public.contract_items.contract_amount is
  '생성 컬럼 — 수량·단가를 고치면 자동으로 따라간다. 직접 입력하지 말 것.';


-- ───────────────────────────────────────────────────────────────────
-- 계약내역 입력 예시 (실제 계약내역서로 교체할 것)
-- ───────────────────────────────────────────────────────────────────
-- insert into public.contract_items
--   (menu, cat, spec, zone, description, unit, contract_qty, unit_price, wbs, sort_no)
-- values
--   ('전기','전선관','50A','',  '전선관 설치 50A','M', 10000, 25000,'WBS-3-1', 10),
--   ('전기','CABLE TRAY','300W','SCC','케이블트레이 300W','M', 4200, 68000,'WBS-3-2', 20)
-- on conflict (menu, cat, spec, zone) do update set
--   description     = excluded.description,
--   unit            = excluded.unit,
--   contract_qty    = excluded.contract_qty,
--   unit_price      = excluded.unit_price,
--   wbs             = excluded.wbs,
--   sort_no         = excluded.sort_no,
--   updated_at      = now();

-- ###################################################################
-- ##  SUPABASE_REPORT_APPROVAL.sql
-- ###################################################################

-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_REPORT_APPROVAL.sql
-- daily_reports 승인 계층 — 승인된 일보만 공정률·기성에 반영하기 위한 확장
--
-- 작성 2026-08-14 / 적용 순서 2번 (CONTRACT_ITEMS 다음)
--
-- 【기존 status 를 건드리지 않는 이유】
--   status 는 현재 'draft' → 'submitted' 2단계이고, 코드 5곳이 === 정확 비교를 한다.
--     report/app/admin.html:964   var isSub = r.status==='submitted'
--     report/app/admin.html:997   status==='submitted' ? '제출완료' : '작성중'
--     report/app/admin.html:998   status==='submitted' ? PDF링크 : ''
--     report/app/index.html:1921  var isSub = r.status==='submitted'
--     report/app/report-pdf.html:433  if(row.status==='submitted')
--   여기에 'approved' 를 새 값으로 넣으면 승인하는 순간 "제출완료"가 "작성중"으로
--   뒤바뀌고 PDF 버튼이 사라진다.
--
--   그래서 승인은 별도 컬럼 approval 로 분리한다. 두 개념은 원래 직교한다.
--     status   = 작성 진행상태 (draft | submitted)      ← 기존, 손대지 않음
--     approval = 승인 상태     (pending | approved | rejected)  ← 신규
--   기존 5곳은 한 줄도 고칠 필요가 없다.
-- ═══════════════════════════════════════════════════════════════════

alter table public.daily_reports
  add column if not exists approval      text not null default 'pending',
  add column if not exists approved_by   text,
  add column if not exists approved_at   timestamptz,
  add column if not exists reject_reason text,
  add column if not exists locked        boolean not null default false;

-- 오타 값이 들어가면 그 일보는 기성에서 통째로 누락된다
alter table public.daily_reports
  drop constraint if exists daily_reports_approval_chk;
alter table public.daily_reports
  add constraint daily_reports_approval_chk
  check (approval in ('pending','approved','rejected'));

create index if not exists daily_reports_approval_idx
  on public.daily_reports (approval, date);

comment on column public.daily_reports.approval is
  '승인상태. status(작성상태)와 별개. 공정률·기성은 approved 만 집계한다.';
comment on column public.daily_reports.locked is
  '기성 마감 시 true. 잠긴 일보는 승인상태 변경 불가(close_payment_period 가 설정).';


-- ═══════════════════════════════════════════════════════════════════
-- 승인/반려 처리 RPC
--
-- 클라이언트가 읽고 고쳐 쓰면 두 사람이 동시에 처리할 때 서로를 덮어쓴다
-- (upsert_crew_entry 를 만든 것과 같은 이유). 행 잠금으로 처리한다.
--
-- 권한: manager 이상만 승인·반려할 수 있다. localStorage 는 개발자도구로
--       조작되므로 members 테이블에서 서버가 직접 등급을 확인한다.
-- ═══════════════════════════════════════════════════════════════════
create or replace function public.set_report_approval(
  p_id       text,
  p_approval text,
  p_actor_id text,                    -- members.id
  p_reason   text default null
) returns public.daily_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row  public.daily_reports;
  v_role text;
  v_name text;
begin
  if p_approval not in ('pending','approved','rejected') then
    raise exception '잘못된 승인상태: %', p_approval;
  end if;

  -- 1) 권한 확인 (manager 이상)
  select role, name into v_role, v_name
    from public.members where id = p_actor_id;
  if not found then
    raise exception '등록되지 않은 사용자입니다: %', p_actor_id;
  end if;
  if coalesce(v_role,'worker') not in ('manager','admin') then
    raise exception '승인 권한이 없습니다 (현재 등급: %)', coalesce(v_role,'worker');
  end if;

  -- 2) 대상 일보 잠금
  select * into v_row from public.daily_reports where id = p_id for update;
  if not found then
    raise exception '일보 없음: %', p_id;
  end if;

  -- 3) 기성 마감된 일보는 승인상태를 바꿀 수 없다
  if v_row.locked then
    raise exception '기성 마감된 일보입니다. 마감 해제 후 처리하세요: %', p_id;
  end if;

  -- 4) 작성중(draft) 일보는 승인 대상이 아니다
  if p_approval = 'approved' and coalesce(v_row.status,'') <> 'submitted' then
    raise exception '제출되지 않은 일보는 승인할 수 없습니다: %', p_id;
  end if;

  -- 5) 반려는 사유 필수
  if p_approval = 'rejected' and coalesce(btrim(p_reason),'') = '' then
    raise exception '반려 사유를 입력해야 합니다';
  end if;

  update public.daily_reports set
    approval      = p_approval,
    approved_by   = case when p_approval = 'approved' then v_name else null end,
    approved_at   = case when p_approval = 'approved' then now()  else null end,
    reject_reason = case when p_approval = 'rejected' then p_reason else null end,
    updated_at    = now()
  where id = p_id
  returning * into v_row;

  return v_row;
end $$;

comment on function public.set_report_approval is
  '일보 승인/반려. manager 이상만 가능, 마감된 일보는 거부, 반려 시 사유 필수.';


-- ═══════════════════════════════════════════════════════════════════
-- 소급 승인 (최초 1회만 실행)
--
-- approval 기본값이 'pending' 이라 컬럼 추가 직후에는 기존 일보 전체가
-- 미승인이 된다. 이 상태로 v_contract_progress 를 보면 공정률이 0% 로 나온다.
-- 이미 제출 완료된 과거 일보는 승인된 것으로 간주하고 소급 처리한다.
-- ═══════════════════════════════════════════════════════════════════
update public.daily_reports
   set approval    = 'approved',
       approved_by = '소급일괄(2026-08-14)',
       approved_at = now(),
       updated_at  = now()
 where status = 'submitted'
   and approval = 'pending';

-- 확인용
-- select approval, status, count(*) from public.daily_reports group by 1,2 order by 1,2;

-- ###################################################################
-- ##  SUPABASE_PAYMENT_VIEWS.sql
-- ###################################################################

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

-- ###################################################################
-- ##  SUPABASE_PAYMENT_TABLES.sql
-- ###################################################################

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

-- ###################################################################
-- ##  SUPABASE_CONTRACT_EVERGREEN.sql  (2026-08-14 추가 — 단가 3분할·간접비)
-- ###################################################################

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

-- ###################################################################
-- ##  SUPABASE_PAYMENT_PERIODS_V2.sql  (2026-08-14 — 회차별 3분할·실시간 집계)
-- ###################################################################

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
