# DATA_MODEL.md — 데이터 모델

## 목적
daesun 생태계(report/payment/shoot/gallery/progress/checkin/status/material/log)가 공유하는 Supabase 테이블·뷰·RPC를 정리한다. 한 앱만 보고 스키마를 바꾸면 다른 앱이 깨진다 — 수정 전 "어느 앱이 이 테이블을 쓰는가" 절을 먼저 확인할 것.

## 핵심 테이블

### daily_reports (작업일보 — 생태계의 중심 테이블)
`id = '{team}_{date}'` (팀+날짜 단위 1행). `date`는 date형이 아니라 **text**('YYYY-MM-DD') — 사전순 비교로 범위 조건이 동작한다.

| 컬럼 | 타입 | 의미 |
|---|---|---|
| id | text PK | `{team}_{date}` |
| team / date | text | 팀명 / 작업일 |
| status | text | draft \| submitted — **작성 진행상태** |
| approval | text | pending \| approved \| rejected — **승인상태** (status와 직교, 2026-08-14 추가) |
| approved_by / approved_at / reject_reason | text/timestamptz/text | 승인 처리 기록 |
| locked | boolean | 기성 마감(`close_payment_period`)이 세팅. true면 승인상태·items 수정 불가 |
| items | jsonb[] | 작업 항목 배열 — `{menu,cat,tag,spec,qty,unit,status(진행\|완료\|변경전\|변경후),note,submitted,photo}` |
| crew | jsonb[] | 출퇴근 — `{member_id,member_name,checkInAt,checkOutAt,overtimeCheckAt,checkInDistanceM}` |
| equipment | jsonb[] | 장비 사용 — `{name,qty}` |
| tbm_photo | text | TBM 사진 URL |
| writer_name / writer_id | text | 제출자 기록(행 생성자와 다를 수 있음, 2026-08-09 추가) |
| updated_at | timestamptz | |

- **읽고/쓰는 앱**: report(작성/승인/조회 전부), payment(승인+기간 범위로 읽기, 마감 시 locked만 씀), checkin(crew만), progress(읽기, CHECK LIST/공정률 원천), log(PDF 생성용 읽기).
- **동시편집 보호**: items는 `upsert_report_item`/`delete_report_item` RPC로 항목 단위 저장(배열 통째 덮어쓰기 아님, `app/index.html:1605,1623`). crew는 `upsert_crew_entry` RPC. **equipment는 아직 항목 단위 RPC 없음** — 배열 통째 저장 방식이 남아있어 동시편집 유실 위험이 이론상 있음(실사용 빈도 낮아 미발견 상태로 추정).
- **(menu,cat,spec,zone) 조인 키**: items[]의 menu/cat/spec/loc(zone)은 `contract_items`의 같은 이름 필드와 **글자까지 일치**해야 기성 집계에 잡힌다.

### app_settings (id='global' 단일행 — 전 앱 공용 설정)
upsert 시 제공된 컬럼만 갱신되므로 필드를 계속 추가해도 서로 덮어쓰지 않는다.

| 컬럼 | 의미 | 쓰는 화면 |
|---|---|---|
| cats_by_menu | 공종별 작업분류 목록 | report 설정, payment(작업분류 조회) |
| areas | 작업구역 목록 | report, gallery |
| personnel / equipment | 인원/장비 관리 목록 | report |
| site_lat / site_lng / geofence_m | 출퇴근 반경 게이트(1km 고정) | checkin, report(인원 탭) |
| plan_qty / install_qty / cat_factor | 공정률 계획수량/설치수량(엑셀)/가중치(FACTOR) | report admin, progress(실시간 연동) |
| item_unit | 작업분류별 단위(표시 전용, 계산엔 안 씀) | report, status |
| site_supabase_url / site_supabase_key | 멀티테넌트 접속 대상(2026-08 하순 추가) | report/gallery/progress **만** (나머지 6개 앱 미반영 — 알려진 제약 참고) |

### members (로그인/권한)
전화번호로 로그인. `role`: worker(0) < manager(1) < admin(2). `is_leader`로 팀 대표 구분. `email`(2026-08-27 추가, 본인확인용이지 로그인 수단 아님), `menu`/`cat`(가입 시 공종/분류).
- **role-gate.js/nav-fab.js**(report 루트 원본, 나머지 앱은 `/report/role-gate.js` 절대경로로 로드)가 `localStorage.member_role`로 화면 접근을 가른다 — **서버측 차단이 아니라 화면 숨김 수준**(개발자도구로 조작 가능).
- payment 앱만 예외적으로 role-gate를 쓰지 않는다(계정 비연동, 공용 PIN 방식).

## 기성/계약 테이블 (2026-08-14 도입, `work-payment-daesun`이 주 사용처)

### contract_items — 계약내역 마스터
키: `(menu, cat, spec, zone)` unique. `spec`/`zone` 빈 문자열 허용(NULL 금지), `zone=''`이면 전 구역 공통 계약. `unit_price = mat_price + labor_price + expense_price`(체크 제약, 2026-08-14 EVERGREEN 보강분). `contract_amount`는 `contract_qty × unit_price` generated column. `is_lot`(총액계약), `discipline`/`group1`/`item_no`(기성내역서 계층), `sort_no`(출력순서), `active`.
- **plan_items와 다른 테이블이다** — plan_items는 (cat,tag,spec) TAG 단위 계획/설치수량(progress 공정률용), contract_items는 (menu,cat,spec,zone) 항목 단위 계약수량·단가(기성용). 합치지 않는다.

### indirect_items — 간접공사비 7종(안전관리비/고용보험료/건강보험료/국민연금/장기요양/기계대여보증/공과잡비)
`basis`(direct_labor\|direct_total\|health_insurance\|fixed) × `rate`(numeric(12,9), 9자리 — 6자리로는 원 단위 오차 발생)로 산출. **DB 뷰(v_indirect_progress 등)까지는 구현됐지만 payment/report 어느 화면 코드에서도 조회하지 않는다** — 기능은 존재하나 UI에 아직 연결 안 됨(알려진 제약 참고).

### payment_periods — 기성 회차
`seq_no` unique, `status`: open→closed→invoiced 3단계. `advance_deduction`/`retention_amount`/`other_deduction`/`vat_rate`(회차 단위 공제).

### payment_lines — 회차×계약항목 확정 실적
`(period_id, contract_id)` unique. `qty_this/amount_this`(금회) + `mat_this/labor_this/expense_this`(3분할) + `cum_*`(누계, **회차 마감 시점 값을 고정 저장** — 이후 단가가 바뀌어도 과거 청구액은 변하지 않음).

### payment_report_link — 일보→회차 편입 (이중청구 방지)
`report_id`에 **전역 UNIQUE 인덱스** — 하나의 일보는 평생 한 회차에만 편입 가능(DB 제약 수준, 코드 버그로도 안 뚫림).

## 집계 뷰 (읽기 전용, 실물 저장 없음)

| 뷰 | 정의 | 비고 |
|---|---|---|
| v_daily_work | daily_reports.items를 행으로 펼침 | FCN(변경전/변경후)도 `is_fcn`으로 표시하되 포함 |
| v_billable_work | v_daily_work 중 approval='approved' AND NOT is_fcn, contract_items와 (menu,cat,spec,zone) 매칭 | **기성 집계의 원천**, contract_id null=미계약 |
| v_contract_progress | 계약 대비 누계 진도율, over_contract(초과 여부, 자동 절삭 안 함) | |
| v_uncontracted_work | v_billable_work 중 contract_id null 집계 | 기성 본표 제외 대상 |
| v_fcn_work | is_fcn=true 건만 | 물량엔 안 잡히지만 이력 조회용 |
| v_project_progress | Σ누계기성금액/Σ계약금액 (금액 가중) | progress 앱의 FACTOR 가중평균과 산식이 다름 — 두 값이 다를 수 있음, 대조 필요 |
| v_direct_cost_split / v_indirect_progress / v_payment_rollup | 직접비 재료비·노무비·경비 분해 → 간접비 산출 → 집계표 | **현재 어떤 화면도 조회하지 않음(미사용)** |
| v_payment_summary | 회차별 청구요약(공제·VAT 반영) | 미사용(정의만 존재) |
| v_payment_by_period | 회차별 롱포맷(마감 회차=확정값, open 회차=실시간 집계) | payment 앱이 사용 |

## RPC 목록

| RPC | 파라미터 | 용도 | 호출처 |
|---|---|---|---|
| upsert_report_item | p_id,p_team,p_date,p_item,p_index? | items[] 항목 단위 upsert(동시편집 보호) | report/app/index.html |
| delete_report_item | p_id,p_menu,p_cat,p_tag,p_spec | items[] 항목 삭제 | report/app/index.html |
| set_report_approval | p_id,p_approval,p_actor_id,p_reason? | 승인/반려(manager+, 마감 일보 거부, 반려 시 사유 필수) | report/app/admin.html |
| upsert_crew_entry | p_id,p_team,p_date,p_member_id,p_member_name,p_patch | crew[] 항목 단위 upsert(동시편집 보호) | checkin, report |
| sync_work_log | new_rows(jsonb) | work_log 테이블 delete+insert를 트랜잭션 1개로 | report/app/index.html |
| create_monthly_period | p_year,p_month | 월 단위 기성 회차 생성(중복이면 기존 반환) | payment |
| close_payment_period | p_period_id, **p_actor**(text, default '공무') | 승인 일보 편입→항목 집계→누계→일보 잠금→회차 마감. **admin만 실행 가능은 초기 설계뿐, 2026-08-14 마지막 개정(PAYMENT_RLS.sql)에서 members 등급 확인을 제거하고 계정 비연동으로 교체됨** — 인자명이 `p_actor_id`→`p_actor`로 바뀌었으므로 이 최신 시그니처 기준으로 호출할 것 | payment/index.html:584 |
| reopen_payment_period | p_period_id, p_reason, **p_actor**(default '공무') | 마감 해제(사유 필수, invoiced는 해제 불가) | **UI 어디서도 호출 안 함** — SQL Editor 수동 실행 전용으로 남아있는 것으로 추정 |
| payment_summary_at | p_seq_no | 항목×회차 요약(전회누계/금회/누계/잔량) | **미사용** — payment/index.html이 동일 로직을 클라이언트 JS로 중복 구현 |
| refresh_indirect_contract_amounts | 없음(추정, 실제 정의는 SUPABASE_기성계층_ALL.sql/CONTRACT_EVERGREEN 계열 확인 필요) | 계약내역 갱신 후 간접비 기준액 재계산 | site-setup.html 등 신규 현장 온보딩 문서에 실행 안내 없음 |

> **주의**: `close_payment_period`/`reopen_payment_period`는 2026-08-14 안에서만 두 번 시그니처가 바뀌었다(SUPABASE_PAYMENT_TABLES.sql → SUPABASE_PAYMENT_PERIODS_V2.sql → SUPABASE_PAYMENT_RLS.sql 순, **파일 이름의 알파벳 순이 아니라 각 파일 헤더의 "적용 순서" 주석 순서**로 적용됨). RPC를 다시 손댈 때는 반드시 파일 헤더의 적용 순서를 먼저 확인할 것 — 안 그러면 이미 폐기된 시그니처를 기준으로 판단하게 된다.

## report 밖(다른 저장소가 정의/소유)의 공유 테이블
이 저장소의 SQL 파일에는 정의가 없지만 `SUPABASE_RLS_DELETE_GUARD*.sql`의 보호 목록과 코드 grep으로 존재가 확인된 테이블. 정확한 스키마는 해당 테이블을 실제로 쓰는 저장소 기준으로 확인할 것.

| 테이블 | 정황상 주 소유 앱 | 비고 |
|---|---|---|
| plan_items | progress | (cat,tag,spec) TAG 단위 계획/설치수량 — contract_items와 grain 다름(합치지 않음) |
| progress_checklist | progress ↔ report | report의 daily_reports에서 자동 생성, `upsert(onConflict:'tag,cat')`로 갱신(`app/index.html`) |
| attendance_manual | checkin 계열로 추정 | DELETE_GUARD 보호 대상, report 코드에서 미조회 |
| work_photos | shoot/gallery/log | 사진 원본 메타. **DELETE_GUARD 보호 목록에도, 의도적 예외 3개(members/material_moves/workreportdaesun-gallery)에도 없음 — 현재 DELETE 정책 상태 미확인, Supabase 대시보드에서 직접 확인 필요** |
| material_moves | material | DELETE 허용 예외 3개 중 하나(의도적) |
| workreportdaesun-gallery | gallery | DELETE 허용 예외 3개 중 하나(의도적). report 코드도 insert/select로 접근 |
| work_log | report | `sync_work_log` RPC로 갱신, log(PDF 생성기)가 읽음 |
| instrument_index | report/progress 공용(설계상) | TAG NO. 자동완성 참조 테이블(23,094행), **SQL 파일(SUPABASE_INSTRUMENT_INDEX.sql)이 아직 git 미커밋** — Supabase에서 실행 여부 확인 필요, 실행 전까지 이 테이블을 쓰는 기능은 조용히 비활성 |

## RLS / 삭제 보호
`SUPABASE_RLS_DELETE_GUARD_FIX.sql`이 아래 11개 테이블에서 DELETE/ALL 정책을 전부 제거하고 SELECT/INSERT/UPDATE만 anon·authenticated에 허용한다(이름과 무관하게 재실행해도 같은 결과):
`daily_reports, app_settings, progress_checklist, attendance_manual, work_log, plan_items, contract_items, indirect_items, payment_periods, payment_lines, payment_report_link`

전체 스키마에서 DELETE가 허용된 테이블은 의도적으로 3개만 남긴다: `members`(회원 삭제), `material_moves`, `workreportdaesun-gallery`. **이 목록이 3개보다 많아지면(예: 새 정책이 실수로 DELETE를 여는 경우) 사고 징후로 보고 확인할 것** — 파일 맨 끝 확인 쿼리로 즉시 검증 가능.

접근 통제 자체는 RLS가 아니라 anon publishable key 하나를 전 앱이 공유하는 구조라, **키를 아는 사람은 SELECT로 계약단가·인건비 등 민감 데이터를 읽을 수 있다**(SUPABASE_PAYMENT_RLS.sql 자체 주석에서 인지하고 있는 트레이드오프). 실제 차단이 필요해지면 Supabase Auth + `auth.uid()` 기반 정책 전환이 필요하다 — CLAUDE.md 기준 "인증 구조 변경"에 해당하므로 사용자 승인 없이 진행하지 않는다.

## 여러 앱이 공유하는 테이블 — 수정 전 체크리스트
daily_reports/app_settings/members는 report·payment·shoot·gallery·progress·checkin·status·log 중 3개 이상이 동시에 참조한다. 이 세 테이블의 컬럼을 추가/변경/삭제하기 전에는:
1. 위 표에서 "누가 읽고/쓰는지"를 먼저 확인한다.
2. 컬럼을 새로 추가할 땐 기본값을 주거나 "없으면 그 값만 빼고 저장" 패턴(이 저장소 전반에 이미 적용된 관례, 예: `SUPABASE_MEMBERS_EMAIL.sql`/`SUPABASE_MEMBERS_MENU_CAT.sql` 주석)을 따라 SQL 미실행 상태에서도 다른 앱이 안 깨지게 한다.
3. 8개 이상 저장소로 쪼개진 구조라 report의 새 공용 컬럼/기능이 자동으로 다른 저장소에 퍼지지 않는다 — 배포 후 관련 저장소에도 반영해야 하는지 별도로 확인한다.
