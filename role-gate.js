/* 3단계 권한 공용 게이트 (2026-08-09).
   admin-gate.js / nav-fab.js와 같은 방식으로, 이 파일 하나만 고치면 전체 앱에 반영된다.

     worker  작업자              — 출력일지(checkin) + 작업사진(shoot). 작업일보는 못 봄
     manager 현장관리자 · 팀장   — 작업일보 전체(일보/사진목록/공정률/인원/자재). 관리자화면 제외
     admin   운영관리자          — 전부

   팀장은 현장관리자와 같은 등급이다(2026-08-10, 사용자 확정) — 팀 대표 구분이
   필요하면 members.is_leader를 쓰고 등급은 나누지 않는다.

   쓰는 법: 보호할 페이지의 <head>에 등급을 지정해서 넣는다.
     <script src="/report/role-gate.js" data-require="manager"></script>

   로그인 여부는 각 앱이 이미 자기 가드를 갖고 있으므로 여기서 건드리지 않는다.
   등급이 모자라면 그 사람이 실제로 쓸 수 있는 화면(출력일지)으로 돌려보낸다.

   주의: 이건 화면을 감추는 것이지 서버측 차단이 아니다. localStorage 값은 개발자도구로
   고칠 수 있다. 현장 인원만 주소를 아는 폐쇄 환경이라 "실수 방지" 수준으로 두는 것이고,
   진짜 차단이 필요해지면 Supabase Auth + RLS로 가야 한다. */
(function () {
  var ORDER = { worker: 0, manager: 1, admin: 2 };
  var WORKER_HOME = '/checkin/index.html';
  // 2026-08-22: 다른 현장/회사가 site-setup.html로 자체 Supabase에 연결했으면 그 값을 써야
  // 등급 조회가 그 현장 데이터를 보게 된다 — 여기만 하드코딩돼 있어서 role-gate가 항상 대선
  // 기본 프로젝트를 보는 문제가 있었음(다른 파일들은 이미 이 fallback 패턴 적용됨).
  var SB_URL = localStorage.getItem('site_supabase_url') || 'https://feymoykefzfwucbrqoja.supabase.co';
  var SB_KEY = localStorage.getItem('site_supabase_key') || 'sb_publishable_ANT6G7_ka3IPHRk_4vLtBg_7G9NWW7i';

  var script = document.currentScript;
  var need = (script && script.getAttribute('data-require')) || 'worker';

  /* 로그인 처리는 기본적으로 각 앱이 이미 갖고 있는 자기 가드에 맡긴다(앱마다 로그인 후
     돌아갈 화면이 다르기 때문). 가드가 아예 없는 페이지(관리자 화면·PDF·자재관리)만
     data-login으로 보낼 곳을 지정해서 여기서 막는다. */
  var memberId = localStorage.getItem('member_id');
  if (!memberId) {
    var loginUrl = script && script.getAttribute('data-login');
    if (loginUrl) location.replace(loginUrl);
    return;
  }

  function rank(r) { return ORDER[r] == null ? 0 : ORDER[r]; }

  function publish(role) {
    window.WR_ROLE = role;
    /* 내 등급이 min 이상인가. 화면 안에서 버튼을 보일지 말지 정할 때도 쓴다.
       예) if (!wrRoleAtLeast('admin')) settingsBtn.style.display = 'none'; */
    window.wrRoleAtLeast = function (min) { return rank(role) >= rank(min); };
  }

  /* members.role을 다시 읽어온다. 실패하면(오프라인 등) null을 돌려주고 판정은 기존 값에 맡긴다. */
  function fetchRole() {
    var req = fetch(SB_URL + '/rest/v1/members?select=role&id=eq.' + encodeURIComponent(memberId), {
      headers: { apikey: SB_KEY }
    })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (rows) { return (rows && rows[0] && rows[0].role) || null; })
      .catch(function () { return null; });
    /* 응답이 끝내 안 오면 화면을 계속 가려둔 채로 멈추게 되므로 4초에서 포기한다. */
    var timeout = new Promise(function (done) { setTimeout(function () { done(null); }, 4000); });
    return Promise.race([req, timeout]);
  }

  function enforce(role) {
    if (rank(role) >= rank(need)) return;
    // 이미 돌아갈 화면에 있으면(설정 오류 등) 무한 왕복을 막는다.
    if (location.pathname === WORKER_HOME) return;
    /* 아무 설명 없이 튕기면 "눌렀는데 엉뚱한 화면이 뜬다"로 보이므로, 도착 화면에서 한 번만
       안내하도록 쪽지를 남긴다(sessionStorage라 탭을 닫으면 사라진다). */
    try {
      sessionStorage.setItem('wr_role_denied', JSON.stringify({ need: need, role: role }));
    } catch (e) {}
    location.replace(WORKER_HOME);
  }

  var stored = localStorage.getItem('member_role');

  if (stored) {
    /* 평소 경로 — 저장된 등급으로 즉시 판정하고, 등급이 바뀌었을 수 있으니 뒤에서 갱신만 해둔다.
       (운영자가 admin.html에서 등급을 올려줘도 예전엔 재로그인해야 반영됐다.) */
    publish(stored);
    window.WR_ROLE_READY = Promise.resolve(stored);
    enforce(stored);
    fetchRole().then(function (fresh) {
      if (fresh && fresh !== stored) localStorage.setItem('member_role', fresh);
    });
    return;
  }

  /* member_role이 아예 없는 세션 — 2026-08-09에 권한이 도입되기 전에 로그인해둔 사람들이다.
     예전엔 여기서 그냥 worker로 깎아버려서, 실제로는 운영자인 사람까지 모든 화면이
     출퇴근체크로 튕겨나가 앱을 아예 못 쓰는 상태가 됐다(2026-08-10 신고).
     이제는 판정을 미루고 members에서 진짜 등급을 받아온 다음에 결정한다. */
  publish('worker');
  document.documentElement.style.visibility = 'hidden';   // 판정 전 화면이 깜빡이는 것 방지
  window.WR_ROLE_READY = fetchRole().then(function (fresh) {
    var role = fresh || 'worker';
    localStorage.setItem('member_role', role);
    publish(role);
    document.documentElement.style.visibility = '';
    enforce(role);
    return role;
  });
})();
