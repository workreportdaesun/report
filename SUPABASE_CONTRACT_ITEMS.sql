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
