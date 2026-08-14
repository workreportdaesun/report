-- ═══════════════════════════════════════════════════════════════════
-- SUPABASE_REPORT_ITEM_RPC.sql
-- 작업일보 items 를 항목 단위로 저장한다 (배열 통째 덮어쓰기 제거)
--
-- 작성 2026-08-14 / 개선 4번 — 아직 프론트에 붙이지 않았다
--
-- 【문제】
--   report/app/index.html 이 items 배열을 통째로 써넣는다.
--       upsertDailyReport({items:items, status:computeReportStatus(items)});   // 5곳
--   같은 팀 두 사람이 같은 날 일보를 동시에 편집하면 나중 저장이 먼저 저장을 지운다.
--   일보는 (team, date) 단위라 실제로 발생 가능하다.
--
--   출퇴근(crew)에서 이미 같은 사고가 났고 upsert_crew_entry RPC 로 고쳐서
--   8명 동시 호출 시험을 통과했다(2026-08-10). items 만 그 패턴이 안 들어가 있다.
--
-- 【해결】
--   행을 잠그고(for update) 서버에서 해당 항목만 바꾼다.
--   항목 식별키는 (menu, cat, tag, spec) — 같은 기기·같은 규격의 같은 작업이면
--   같은 항목으로 본다. tag 가 없는 항목(수량만 있는 작업)은 키가 겹칠 수 있어
--   p_index 로 위치를 직접 지정할 수 있게 열어뒀다.
--
-- 【이 파일을 실행해도 지금은 아무 변화가 없다】
--   함수만 추가될 뿐 부르는 코드가 없다. 프론트 전환은 별도로 한다.
--   전환 시 upsertDailyReport 의 items 통째 저장을 이 RPC 호출로 바꾸고,
--   PGRST202(함수 없음)면 옛 경로로 물러서는 폴백을 crew 때처럼 남겨둘 것.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.upsert_report_item(
  p_id     text,        -- daily_reports.id
  p_team   text,        -- 행이 없을 때 새로 만들 때 쓴다
  p_date   text,        -- 'YYYY-MM-DD' (daily_reports.date 는 text 형)
  p_item   jsonb,       -- 저장할 항목 하나 {menu,cat,tag,spec,qty,unit,status,...}
  p_index  integer default null   -- 위치를 직접 지정할 때(키가 겹치는 항목)
) returns public.daily_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row   public.daily_reports;
  v_items jsonb;
  v_idx   integer := null;
  i       integer;
  v_cur   jsonb;
begin
  if p_item is null or jsonb_typeof(p_item) <> 'object' then
    raise exception 'p_item 은 JSON 객체여야 합니다';
  end if;

  -- 1) 행 잠금. 없으면 만든다 (오늘 첫 저장을 두 곳에서 동시에 시도하는 경우 대비)
  select * into v_row from public.daily_reports where id = p_id for update;
  if not found then
    insert into public.daily_reports (id, team, date, status, items, crew)
    values (p_id, p_team, p_date, 'draft', '[]'::jsonb, '[]'::jsonb)
    on conflict (id) do nothing;
    select * into v_row from public.daily_reports where id = p_id for update;
  end if;

  if v_row.locked then
    raise exception '기성 마감된 일보는 수정할 수 없습니다: %', p_id;
  end if;

  v_items := case when jsonb_typeof(v_row.items) = 'array'
                  then v_row.items else '[]'::jsonb end;

  -- 2) 바꿀 위치 찾기
  if p_index is not null then
    if p_index >= 0 and p_index < jsonb_array_length(v_items) then
      v_idx := p_index;
    end if;
  else
    for i in 0 .. greatest(jsonb_array_length(v_items) - 1, 0) loop
      v_cur := v_items -> i;
      if v_cur is not null
         and coalesce(v_cur->>'menu','') = coalesce(p_item->>'menu','')
         and coalesce(v_cur->>'cat','')  = coalesce(p_item->>'cat','')
         and coalesce(v_cur->>'tag','')  = coalesce(p_item->>'tag','')
         and coalesce(v_cur->>'spec','') = coalesce(p_item->>'spec','')
      then
        v_idx := i;
        exit;
      end if;
    end loop;
  end if;

  -- 3) 있으면 병합, 없으면 추가 (crew 와 같은 방식)
  if v_idx is null then
    v_items := v_items || jsonb_build_array(p_item);
  else
    v_items := jsonb_set(v_items, array[v_idx::text], (v_items -> v_idx) || p_item);
  end if;

  update public.daily_reports
     set items = v_items, updated_at = now()
   where id = p_id
  returning * into v_row;

  return v_row;
end $$;

comment on function public.upsert_report_item is
  '작업일보 items 를 항목 단위로 저장. 배열 통째 덮어쓰기로 인한 동시편집 유실을 막는다(upsert_crew_entry 와 같은 패턴).';


-- ───────────────────────────────────────────────────────────────────
-- 항목 삭제 — 프론트에서 행을 지울 때 쓴다
-- ───────────────────────────────────────────────────────────────────
create or replace function public.delete_report_item(
  p_id    text,
  p_menu  text,
  p_cat   text,
  p_tag   text,
  p_spec  text
) returns public.daily_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row   public.daily_reports;
  v_items jsonb := '[]'::jsonb;
  v_cur   jsonb;
  i       integer;
begin
  select * into v_row from public.daily_reports where id = p_id for update;
  if not found then raise exception '일보 없음: %', p_id; end if;
  if v_row.locked then
    raise exception '기성 마감된 일보는 수정할 수 없습니다: %', p_id;
  end if;

  for i in 0 .. greatest(jsonb_array_length(
        case when jsonb_typeof(v_row.items)='array' then v_row.items else '[]'::jsonb end) - 1, 0) loop
    v_cur := (case when jsonb_typeof(v_row.items)='array' then v_row.items else '[]'::jsonb end) -> i;
    if v_cur is null then continue; end if;
    if coalesce(v_cur->>'menu','') = coalesce(p_menu,'')
       and coalesce(v_cur->>'cat','')  = coalesce(p_cat,'')
       and coalesce(v_cur->>'tag','')  = coalesce(p_tag,'')
       and coalesce(v_cur->>'spec','') = coalesce(p_spec,'')
    then
      continue;                    -- 이 항목만 빼고 나머지를 다시 모은다
    end if;
    v_items := v_items || jsonb_build_array(v_cur);
  end loop;

  update public.daily_reports
     set items = v_items, updated_at = now()
   where id = p_id
  returning * into v_row;

  return v_row;
end $$;


-- ───────────────────────────────────────────────────────────────────
-- 동시 저장 시험 (선택) — 두 세션이 서로 다른 항목을 동시에 넣어도 둘 다 남아야 한다
-- ───────────────────────────────────────────────────────────────────
-- select public.upsert_report_item('__TEST__','1팀(계장)','2026-08-14',
--   '{"menu":"시공","cat":"CONDUIT PIPE","tag":"T-1","spec":"54mm","qty":10,"unit":"M","status":"진행"}'::jsonb);
-- select public.upsert_report_item('__TEST__','1팀(계장)','2026-08-14',
--   '{"menu":"시공","cat":"CABLE TRAY","tag":"T-2","spec":"300W","qty":5,"unit":"M","status":"진행"}'::jsonb);
-- select jsonb_array_length(items) from public.daily_reports where id='__TEST__';   -- 2 여야 정상
-- delete from public.daily_reports where id='__TEST__';   -- 시험 후 정리 (SQL Editor 에서만 가능)
