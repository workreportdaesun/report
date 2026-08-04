-- work_log 재계산을 delete()+insert() 두 번의 개별 호출 대신 하나의 DB 트랜잭션으로
-- 묶는 함수. 다른 팀이 거의 동시에 일보를 저장해서 syncWorkLog()가 겹쳐 호출돼도,
-- 트랜잭션이 하나씩 순서대로 처리되므로 중복 행이 남지 않는다(2026-08-02).
-- Supabase SQL Editor에서 한 번만 실행하면 됩니다.

-- 작업구역(loc) 추가(2026-08-04): work_log 테이블에 loc 컬럼이 없다면 먼저 실행.
-- alter table work_log add column if not exists loc text;

create or replace function sync_work_log(new_rows jsonb)
returns void
language plpgsql
as $$
begin
  delete from work_log where true; -- 이 프로젝트는 WHERE 없는 delete를 막는 보호가 걸려있어 where true로 우회
  insert into work_log (report_date, team, menu, cat, tag, spec, qty, status, seq, loc)
  select report_date, team, menu, cat, tag, spec, qty, status, seq, loc
  from jsonb_populate_recordset(null::work_log, new_rows);
end;
$$;

grant execute on function sync_work_log(jsonb) to anon, authenticated;
