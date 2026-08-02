-- 회원가입 시 공종(menu)/작업분류(cat)를 함께 저장하기 위한 컬럼 추가.
-- 이 컬럼이 없어도 가입 자체는 막히지 않지만(login.html이 없는 컬럼은 자동으로 빼고 재시도),
-- 실제로 값을 저장하려면 Supabase SQL Editor에서 한 번 실행해야 합니다.

alter table members add column if not exists menu text;
alter table members add column if not exists cat text;
