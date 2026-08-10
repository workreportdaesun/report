-- 출근/퇴근/연장 체크를 daily_reports.crew 배열에 원자적으로 병합하는 함수 (2026-08-10).
-- Supabase SQL Editor에서 한 번만 실행하면 됩니다.
--
-- 왜 필요한가
--   지금까지 출퇴근체크(work-checkin-daesun)와 작업일보 인원현황의 출력체크는
--   ① crew 배열을 통째로 읽고 ② 자기 항목을 넣고 ③ 통째로 다시 쓰는 방식이었다.
--   같은 팀 두 사람이 몇 초 안에 체크하면 나중 사람이 "먼저 사람이 체크하기 전"의
--   배열을 읽어서 그대로 덮어써버려, 먼저 찍은 사람의 기록이 사라진다.
--   아침 07시에 팀원이 한꺼번에 찍는 게 정상 상황이라 실제로 터진다.
--
--   이 함수는 그 세 단계를 DB 안에서 한 트랜잭션으로 처리하고, 행을 FOR UPDATE로
--   잠그기 때문에 같은 행을 건드리는 다른 호출은 순서대로 기다렸다 처리된다.
--
-- 참고: daily_reports.date는 date형이 아니라 text형이다(2026-08-10 확인) — 그래서
--       p_date도 text로 받는다. 나중에 date형으로 바꾸면 이 함수도 같이 고쳐야 한다.

create or replace function upsert_crew_entry(
  p_id          text,
  p_team        text,
  p_date        text,
  p_member_id   text,
  p_member_name text,
  p_patch       jsonb
)
returns jsonb
language plpgsql
as $$
declare
  v_crew  jsonb;
  v_idx   int;
  v_entry jsonb;
begin
  -- 오늘 이 팀의 행이 아직 없으면 만든다. 두 사람이 동시에 들어와도 하나만 실제로
  -- 삽입되고 나머지는 조용히 넘어간다.
  insert into daily_reports (id, team, date, status, items, crew, updated_at)
  values (p_id, p_team, p_date, 'draft', '[]'::jsonb, '[]'::jsonb, now())
  on conflict (id) do nothing;

  -- 여기서 행을 잠근다. 읽고-고치고-쓰는 사이에 다른 호출이 끼어들 수 없다.
  select crew into v_crew from daily_reports where id = p_id for update;
  if v_crew is null or jsonb_typeof(v_crew) <> 'array' then
    v_crew := '[]'::jsonb;
  end if;

  -- 내 항목이 배열 몇 번째에 있는지(없으면 null)
  select i - 1 into v_idx
  from generate_series(1, jsonb_array_length(v_crew)) as i
  where v_crew -> (i - 1) ->> 'member_id' = p_member_id
  limit 1;

  if v_idx is null then
    v_entry := jsonb_build_object('member_id', p_member_id, 'member_name', p_member_name) || p_patch;
    v_crew  := v_crew || jsonb_build_array(v_entry);
  else
    -- 기존 항목 위에 patch에 담긴 키만 덮어쓴다(출근 기록을 지우지 않고 퇴근만 추가하는 식).
    v_entry := (v_crew -> v_idx) || p_patch;
    v_crew  := jsonb_set(v_crew, array[v_idx::text], v_entry);
  end if;

  update daily_reports
     set crew = v_crew, updated_at = now()
   where id = p_id;

  return v_entry;
end;
$$;

grant execute on function upsert_crew_entry(text, text, text, text, text, jsonb) to anon, authenticated;
