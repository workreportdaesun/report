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
