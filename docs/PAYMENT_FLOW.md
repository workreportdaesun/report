# PAYMENT_FLOW.md — 기성 데이터 흐름

## 원칙 (CLAUDE.md 인용)
- 승인된 작업실적만 공식 공정/기성에 반영한다.
- 미승인/반려 작업은 공식 기성에서 제외한다.
- 계약수량 초과를 자동 절삭하지 않는다.
- FCN/변경 작업을 일반 계약수량과 혼합하지 않는다.
- 기성수량은 원천 작업실적까지 추적 가능해야 한다.
- 금액은 금회수량 × 적용단가로 검증한다.

아래는 이 6가지 원칙이 실제로 어느 테이블/뷰/RPC에서 구현됐는지를 단계별로 정리한다. 화면 관점(항목/버튼/탭)은 `UI_PAYMENT.md`를 보고, 이 문서는 데이터가 어디서 와서 어디로 가는지(로직) 관점으로 작성한다.

## 전체 흐름
```
작업일보 입력            daily_reports.items[]  (report 작업자 화면)
  ↓
승인                     daily_reports.approval  (set_report_approval RPC, report 관리자)
  ↓
행 단위 펼침 + FCN 표시  v_daily_work            (approval·is_fcn 포함 전부)
  ↓
승인+FCN제외 필터        v_billable_work         (approval='approved' AND NOT is_fcn)
  ↓
계약 ITEM 매칭           contract_items          ((menu,cat,spec,zone) 키로 조인, 미매칭=contract_id null)
  ↓
회차 집계(열린 회차)     v_payment_by_period      (open: 실시간 / closed·invoiced: 확정값)
  ↓
마감                     close_payment_period RPC (편입→집계→누계→locked→closed)
  ↓
청구서 조회              payment_lines, v_payment_summary  (work-payment-daesun UI)
```

## 1) 승인된 작업실적만 반영 — 구현: `daily_reports.approval` + `v_billable_work`
`status`(작성 진행: draft/submitted)와 `approval`(승인: pending/approved/rejected)은 **의도적으로 분리된 별개 컬럼**이다(2026-08-14). 이유: 기존 코드 5곳이 `status==='submitted'`를 "제출완료" 판정에 쓰고 있어서, 승인 값을 status에 얹으면 승인하는 순간 화면이 "작성중"으로 뒤바뀐다. `set_report_approval` RPC는 manager 이상만 호출 가능(members.role을 서버에서 직접 조회, localStorage 값은 안 믿음), 제출되지 않은(draft) 일보는 승인 대상에서 거부, 반려는 사유 필수. 기성 집계의 유일한 원천 뷰 `v_billable_work`는 `where w.approval = 'approved'` 한 줄로 이 규칙을 강제한다.

## 2) 미승인/반려 작업 제외 — 구현: 동일 필터(위)
`v_billable_work`는 approved만 통과시키므로 pending/rejected 항목은 애초에 이 뷰에 나타나지 않는다. rejected 건은 `daily_reports.reject_reason`에 사유가 남아 재작성 대상으로만 존재한다.

## 3) 계약수량 초과 자동 절삭 금지 — 구현: `v_contract_progress.over_contract`
누계수량(`cum_qty`)이 계약수량(`contract_qty`)을 넘어도 `remain_qty`는 음수로 그대로 계산되고, `over_contract` boolean만 true로 표시한다. 물량을 자르거나 숨기지 않는다 — 화면에서 이 값을 경고로만 노출하면 원칙이 지켜진다.

## 4) FCN/변경 작업 분리 — 구현: `is_fcn` + `v_fcn_work`
`daily_reports.items[].status`가 `'변경전'`/`'변경후'`이면 `v_daily_work.is_fcn = true`. `v_billable_work`는 `and not w.is_fcn`으로 이 건들을 기성 물량에서 원천 제외한다. 제외된 FCN 승인 건은 사라지지 않고 별도 뷰 `v_fcn_work`로 계속 조회 가능(이력 보존, 설계변경 정산은 별도 프로세스로 처리한다는 전제 — **정산 프로세스 자체는 아직 구현 안 됨**, 알려진 제약 참고).

## 5) 원천 작업실적까지 추적 가능 — 구현: `payment_report_link` + 컬럼 체인
기성 금액 → `payment_lines`(회차×계약항목) → `payment_report_link`(회차→일보 id) → `daily_reports`(팀/날짜/작성자/원본 items) → items[]의 tag/사진(work_photos, report_id로 연결)까지 역추적 가능한 체인이 테이블 구조상 존재한다. **다만 이 역추적을 한 화면에서 클릭 한 번으로 보여주는 UI는 아직 없다** — 현재는 여러 테이블을 수동으로 대조해야 한다(알려진 제약).

## 6) 금액 = 금회수량 × 적용단가 — 구현: `close_payment_period` RPC
마감 시 `amount_this = round(sum(qty) * c.unit_price, 0)`로 계산해 `payment_lines`에 저장한다. EVERGREEN 보강 이후 단가는 재료비(mat_price)+노무비(labor_price)+경비(expense_price)로 3분할 저장되며 `unit_price = mat_price+labor_price+expense_price`를 DB 체크 제약으로 강제한다(어긋나면 계약 등록 자체가 거부됨).

## 이중청구 방지
`payment_report_link.report_id`에 **전역 UNIQUE 인덱스**를 걸어, 하나의 일보가 두 회차에 동시에 편입되는 것을 코드 로직이 아니라 DB 제약으로 막는다. `close_payment_period`가 대상 일보를 편입할 때도 `not exists`로 먼저 걸러 이중 삽입 자체가 안 일어나게 한다.

## 마감(월 단위 회차)
`create_monthly_period(year, month)`로 해당 월 전체를 기간으로 하는 회차를 만든다(같은 기간이 이미 있으면 새로 만들지 않고 기존 회차 반환). `close_payment_period`는:
1. 기간 내 approved 일보를 회차에 편입(이중청구 방지 적용)
2. `v_billable_work`를 계약항목별로 집계해 `payment_lines`에 저장(3분할 단가 포함)
3. 이전 회차(seq_no 작은 것) 합계 + 금회 = 누계로 계산
4. 편입된 일보를 `locked=true`로 잠금 — 이후 `set_report_approval`/`upsert_report_item`이 거부됨
5. 회차 상태를 `closed`로 변경

**마감 후 금액은 고정된다** — 이후 `contract_items.unit_price`를 바꿔도 이미 닫힌 회차의 `payment_lines.amount_this/cum_amount`는 재계산되지 않는다(과거 청구액 소급 변경 방지가 의도된 설계). 반대로 열린(open) 회차는 `v_payment_by_period`가 매번 `v_billable_work`에서 실시간 집계하므로 승인 상태가 바뀌면 그 자리에서 숫자가 바뀐다.

`reopen_payment_period(p_period_id, p_reason, p_actor)`로 마감 해제 가능(사유 필수, `invoiced` 상태는 해제 불가) — **UI에는 노출되지 않고 정의만 있다.** CLAUDE.md의 "마감 기성 재오픈은 확인 없이 하지 말 것" 원칙에 맞춰 SQL Editor 수동 실행으로만 열어둔 의도적 설계로 보이나, 실제 의도인지는 확인이 필요하다(⚠️ 사용자 확인 필요 — UI 노출 여부를 임의로 바꾸지 말 것).

## 간접공사비(간접비 7종)
EVERGREEN 실제 기성서류 기준으로 안전관리비/고용보험료/건강보험료/국민연금보험료/노인장기요양보험료/건설기계대여대금 지급보증 수수료/공과잡비 7종을 `indirect_items`에 요율(`rate`, 소수 9자리)로 저장한다. 기준액은 `contract_items`를 재료비/노무비/경비로 3분할한 `v_direct_cost_split`(특히 `cum_labor`=누계 직접노무비)에서 가져온다. `v_indirect_progress`가 항목별 누계 간접비를, `v_payment_rollup`이 직접비+간접비 합계 집계표를 만든다.

**알려진 제약: 이 간접비 체인은 DB(테이블·뷰·RLS)까지는 완성돼 있지만, payment/report 어느 화면 코드에서도 조회하지 않는다.** 즉 계약금액의 약 12.2%를 차지하는 간접공사비가 실제 청구 화면(work-payment-daesun)의 금액에는 아직 반영되지 않고 있을 가능성이 높다 — 화면에 연결하기 전에는 `v_payment_summary`/`v_payment_rollup` 값과 실제 청구서 금액이 다를 수 있음을 유의할 것.

## 알려진 제약 (문서가 그리는 목표와 실제 구현의 차이)
- **기성 워크플로가 6단계(작성→자료수집→검토→증빙확인→기성확정→마감, `UI_PAYMENT.md` 참고)로 설계돼 있지만, 실제 `payment_periods.status`는 open/closed/invoiced 3단계뿐이다.** 세부 단계 컬럼도, "증빙" 개념(업로드/상태)도 스키마·코드 어디에도 없다.
- FCN(설계변경) 정산을 "별도로 처리한다"는 원칙만 있고, 그 별도 처리 자체의 테이블/화면은 없다 — `v_fcn_work`로 조회만 가능한 상태.
- 원천 작업실적 역추적(계약항목→일보→사진)이 테이블 구조상으로는 가능하지만 이를 한 화면에서 보여주는 UI는 없다.
- 간접공사비가 DB에는 구현됐지만 청구 화면에 연결되지 않았다(위 항목).
- `payment_summary_at` RPC(항목×회차 요약)가 정의돼 있지만 미사용 — 같은 로직이 `work-payment-daesun/index.html` 클라이언트 JS에 별도로 중복 구현돼 있다. 둘 중 하나가 바뀌면 다른 하나도 확인해야 한다.
- `reopen_payment_period`가 UI에 노출 안 됨(위 항목).
- 계약내역 신규 업로드 후 필요한 간접비 기준액 재계산(관련 RPC/절차, `SUPABASE_기성계층_ALL.sql`·`CONTRACT_EVERGREEN.sql` 계열)에 대한 안내가 `site-setup.html`(신규 현장 연결 UI)에 없다.

## work-payment-daesun 앱이 실제로 쓰는 것
`app_settings`(cats_by_menu 조회), `contract_items`, `payment_periods`, `payment_lines`, `v_payment_by_period`, RPC `create_monthly_period`/`close_payment_period`. role-gate.js를 쓰지 않고 members 테이블에도 의존하지 않는 **계정 비연동 앱**(공용 PIN 방식) — `close_payment_period`/`reopen_payment_period`도 2026-08-14 마지막 개정에서 members 등급 확인을 제거하고 담당자 이름 문자열(`p_actor`, 기록용)만 받는 버전으로 바뀌었다(DATA_MODEL.md의 RPC 표 참고). indirect_items/v_indirect_progress 등 간접비 관련 테이블·뷰는 이 앱 코드에서 전혀 조회하지 않는다.
