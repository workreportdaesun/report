-- 회원(운영자 포함)이 본인 확인·연락용으로 이메일을 등록할 수 있게 하는 컬럼 추가.
-- 로그인 수단이 아니다 — 전화번호를 잃어버렸을 때(폰 분실 + 번호 변경) 소유자/다른
-- 운영자가 "이 사람이 맞다"를 확인하고 admin.html에서 전화번호만 고쳐 같은 계정을
-- 그대로 되살리는 용도다. 이 컬럼이 없어도 가입/저장 자체는 막히지 않지만(login.html·
-- admin.html이 없는 컬럼은 자동으로 빼고 재시도), 실제로 값을 저장하려면 Supabase
-- SQL Editor에서 한 번 실행해야 합니다.

alter table members add column if not exists email text;
