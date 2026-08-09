-- ════════════════════════════════════════════════════════════════════════
--  "미지정_" 고아 일보 7건 정리 (2026-08-09 기준)
-- ════════════════════════════════════════════════════════════════════════
--
-- 왜 생겼나
--   출퇴근체크/작업사진(shoot) 쪽에서 로그인하면 member_team이 localStorage에
--   저장되지 않아, report의 draftId()가 '미지정_날짜'로 떨어졌다.
--   원인은 2026-08-09에 수정됐고(shoot 커밋 38b9ab7) 이제 새로 생기지 않는다.
--   이 파일은 그 전에 이미 쌓인 7건을 정리하는 것이다.
--
-- 대상 (2026-08-09 확인)
--   ┌────────────┬───────────┬──────┬──────┬────────────────────────────┐
--   │ 날짜       │ 상태      │ 항목 │ 출력 │ 비고                        │
--   ├────────────┼───────────┼──────┼──────┼────────────────────────────┤
--   │ 2026-07-17 │ draft     │   2  │   0  │ 기기번호가 테스트성        │
--   │ 2026-07-25 │ draft     │   1  │   0  │ 기기번호가 테스트성        │
--   │ 2026-07-26 │ draft     │   1  │   0  │ 기기번호가 테스트성        │
--   │ 2026-07-31 │ draft     │   5  │   0  │ DIJB-2151-016 등 실제 형식 │
--   │ 2026-08-04 │ draft     │   7  │   0  │ FV-5685 등 실제 형식       │
--   │ 2026-08-05 │ submitted │  12  │   0  │ ★ 제출 완료 상태           │
--   │ 2026-08-06 │ draft     │  14  │   1  │ 설동석 출근기록 있음       │
--   └────────────┴───────────┴──────┴──────┴────────────────────────────┘
--
-- 먼저 정하실 것: 이 기록들이 진짜 작업 기록인가?
--   7/31·8/4 건은 기기번호가 실제 형식이고, 8/5 건은 제출까지 됐는데 어느 팀
--   일보에도 안 잡혀 있습니다. 실제 작업이었다면 옵션 B로 살리고, 테스트였다면
--   옵션 A로 지우세요. 섞여 있으면 STEP 3의 개별 선택을 쓰세요.
--
-- 실행 순서: STEP 1(백업) → STEP 2(확인) → 옵션 A 또는 B 중 하나만
-- ════════════════════════════════════════════════════════════════════════


-- ─── STEP 0. 컬럼 타입 확인 (옵션 B를 쓸 때만 필요) ────────────────────
-- items/crew가 json인지 jsonb인지에 따라 아래 B-2 병합 구문이 달라집니다.
--   jsonb 로 나오면 → 파일에 적힌 그대로 실행
--   json  으로 나오면 → B-2의 items/crew 대입식 끝에 ::json 을 붙여야 합니다.
--     예) SET items = (COALESCE(...) || COALESCE(...))::json
-- date가 text로 나와도 아래 구문은 그대로 동작합니다(::text 캐스팅으로 맞춰뒀음).

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'daily_reports'
  AND column_name IN ('items', 'crew', 'date');


-- ─── STEP 1. 백업 (반드시 먼저) ────────────────────────────────────────
-- 잘못 지웠을 때 되돌릴 수 있는 유일한 수단입니다. 정리가 끝나고 문제없다고
-- 확인되면 그때 DROP TABLE로 지우세요.

CREATE TABLE IF NOT EXISTS daily_reports_backup_20260809 AS
SELECT * FROM daily_reports WHERE id LIKE '미지정\_%';


-- ─── STEP 2. 지금 상태 확인 ────────────────────────────────────────────
-- 위 표와 같은지 눈으로 대조하세요. 다르면 그 사이에 데이터가 바뀐 것이니
-- 아래 옵션을 그대로 실행하지 마시고 다시 확인해야 합니다.

SELECT id, team, date, status,
       jsonb_array_length(COALESCE(items::jsonb, '[]'::jsonb)) AS 항목수,
       jsonb_array_length(COALESCE(crew::jsonb,  '[]'::jsonb)) AS 출력인원
FROM daily_reports
WHERE id LIKE '미지정\_%'
ORDER BY date;


-- ════════════════════════════════════════════════════════════════════════
--  옵션 A — 전부 삭제 (테스트 데이터였다고 판단한 경우)
-- ════════════════════════════════════════════════════════════════════════
-- STEP 1 백업을 실행한 뒤에만 쓰세요.

-- DELETE FROM daily_reports WHERE id LIKE '미지정\_%';


-- ════════════════════════════════════════════════════════════════════════
--  옵션 B — '관리' 팀 일보로 이관 (실제 작업 기록이라고 판단한 경우)
-- ════════════════════════════════════════════════════════════════════════
-- 행 id가 '팀_날짜' 형식이라 team만 바꾸면 안 되고 id도 같이 바꿔야 합니다.
--
-- ⚠️ 2026-08-06은 이미 '관리_2026-08-06' 행이 있어서(항목 8건) 단순 이름변경이
--    안 됩니다. 그 한 건만 B-2에서 병합하고, 나머지 6건은 B-1로 옮깁니다.
--    (설동석의 소속이 '관리'라 이 팀으로 잡았습니다. 다른 팀이면 아래 '관리'를
--     그 팀 이름으로 바꾸세요.)

-- ─── B-1. 충돌 없는 6건: 팀과 id를 한 번에 변경 ───
-- UPDATE daily_reports
-- SET team = '관리',
--     id   = '관리_' || date::text,
--     updated_at = now()
-- WHERE id LIKE '미지정\_%'
--   AND date::text <> '2026-08-06';

-- ─── B-2. 2026-08-06: 기존 '관리' 행에 항목·출력기록을 합친 뒤 고아 행 삭제 ───
-- 같은 항목이 양쪽에 있으면 두 번 들어갑니다. 합친 뒤 STEP 4로 중복을 확인하세요.
-- UPDATE daily_reports AS tgt
-- SET items = COALESCE(tgt.items::jsonb, '[]'::jsonb) || COALESCE(src.items::jsonb, '[]'::jsonb),
--     crew  = COALESCE(tgt.crew::jsonb,  '[]'::jsonb) || COALESCE(src.crew::jsonb,  '[]'::jsonb),
--     updated_at = now()
-- FROM daily_reports AS src
-- WHERE tgt.id = '관리_2026-08-06'
--   AND src.id = '미지정_2026-08-06';
--
-- DELETE FROM daily_reports WHERE id = '미지정_2026-08-06';


-- ─── STEP 3. (선택) 일부만 살리고 나머지는 삭제 ────────────────────────
-- 실제 기록과 테스트가 섞여 있을 때. 아래는 "7/31·8/4·8/5만 살리고 나머지 삭제"의 예시입니다.
-- 날짜 목록을 실제 판단에 맞게 고쳐 쓰세요.

-- UPDATE daily_reports
-- SET team = '관리', id = '관리_' || date::text, updated_at = now()
-- WHERE id LIKE '미지정\_%'
--   AND date::text IN ('2026-07-31', '2026-08-04', '2026-08-05');
--
-- DELETE FROM daily_reports WHERE id LIKE '미지정\_%';


-- ─── STEP 4. 정리 후 확인 ──────────────────────────────────────────────
-- 첫 쿼리가 0행이면 고아 행이 사라진 것입니다.

SELECT id, team, date, status FROM daily_reports WHERE id LIKE '미지정\_%';

SELECT id, team, date, status,
       jsonb_array_length(COALESCE(items::jsonb, '[]'::jsonb)) AS 항목수
FROM daily_reports ORDER BY date;

-- 8/6을 병합했다면 항목이 8+14=22건이 됐을 것입니다. 중복이 있는지 확인:
-- SELECT it->>'menu' AS 공종, it->>'cat' AS 작업분류, it->>'tag' AS 기기번호, COUNT(*)
-- FROM daily_reports, jsonb_array_elements(items::jsonb) AS it
-- WHERE id = '관리_2026-08-06'
-- GROUP BY 1,2,3 HAVING COUNT(*) > 1;


-- ─── 마무리 ────────────────────────────────────────────────────────────
-- 결과가 만족스러우면 백업 테이블을 지웁니다. 며칠 두고 보셔도 됩니다.
-- DROP TABLE daily_reports_backup_20260809;
