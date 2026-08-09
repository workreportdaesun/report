/* 3단계 권한 공용 게이트 (2026-08-09).
   admin-gate.js / nav-fab.js와 같은 방식으로, 이 파일 하나만 고치면 전체 앱에 반영된다.

     worker  작업자      — 출퇴근체크(checkin)와 본인 출력일수만
     manager 현장관리자  — 작업일보 전체(일보/사진/공정률/인원/조회). 설정·관리자화면 제외
     admin   운영자      — 전부

   쓰는 법: 보호할 페이지의 <head>에 등급을 지정해서 넣는다.
     <script src="/report/role-gate.js" data-require="manager"></script>

   로그인 여부는 각 앱이 이미 자기 가드를 갖고 있으므로 여기서 건드리지 않는다.
   등급이 모자라면 그 사람이 실제로 쓸 수 있는 화면(출퇴근체크)으로 돌려보낸다.

   주의: 이건 화면을 감추는 것이지 서버측 차단이 아니다. localStorage 값은 개발자도구로
   고칠 수 있다. 현장 인원만 주소를 아는 폐쇄 환경이라 "실수 방지" 수준으로 두는 것이고,
   진짜 차단이 필요해지면 Supabase Auth + RLS로 가야 한다. */
(function () {
  var ORDER = { worker: 0, manager: 1, admin: 2 };
  var WORKER_HOME = '/checkin/index.html';

  var role = localStorage.getItem('member_role') || 'worker';
  window.WR_ROLE = role;

  /* 내 등급이 min 이상인가. 화면 안에서 버튼을 보일지 말지 정할 때도 쓴다.
     예) if (!wrRoleAtLeast('admin')) settingsBtn.style.display = 'none'; */
  window.wrRoleAtLeast = function (min) {
    return (ORDER[role] == null ? 0 : ORDER[role]) >= (ORDER[min] == null ? 0 : ORDER[min]);
  };

  var script = document.currentScript;
  var need = (script && script.getAttribute('data-require')) || 'worker';

  /* 로그인 처리는 기본적으로 각 앱이 이미 갖고 있는 자기 가드에 맡긴다(앱마다 로그인 후
     돌아갈 화면이 다르기 때문). 가드가 아예 없는 페이지(관리자 화면·PDF·자재관리)만
     data-login으로 보낼 곳을 지정해서 여기서 막는다. */
  if (!localStorage.getItem('member_id')) {
    var loginUrl = script && script.getAttribute('data-login');
    if (loginUrl) location.replace(loginUrl);
    return;
  }

  if (window.wrRoleAtLeast(need)) return;

  // 이미 돌아갈 화면에 있으면(설정 오류 등) 무한 왕복을 막는다.
  if (location.pathname === WORKER_HOME) return;

  /* 아무 설명 없이 튕기면 "눌렀는데 엉뚱한 화면이 뜬다"로 보이므로, 도착 화면에서 한 번만
     안내하도록 쪽지를 남긴다(sessionStorage라 탭을 닫으면 사라진다). */
  try {
    sessionStorage.setItem('wr_role_denied', JSON.stringify({ need: need, role: role }));
  } catch (e) {}
  location.replace(WORKER_HOME);
})();
