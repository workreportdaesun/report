/* 전체 앱 어디서나 다른 앱으로 바로 이동하는 공용 플로팅 버튼.
   이 파일 하나를 고치면 전체 앱에 반영된다 — 각 페이지에는
   <script src="/report/nav-fab.js"></script> 한 줄만 넣으면 됨.

   min은 role-gate.js의 data-require와 같은 값으로 맞춘다 — 목록에 띄워놓고
   눌렀더니 게이트가 도로 튕겨내는 상황을 막기 위해, 자기 등급으로 못 들어가는
   앱은 아예 목록에서 뺀다. */
function wrBuildNavFab(){
  var ORDER = { worker:0, manager:1, admin:2 };
  var APPS = [
    { key:'checkin',  label:'출력일지',   icon:'🕒', url:'/checkin/index.html',    min:'worker'  },
    { key:'report',   label:'작업일보',   icon:'📋', url:'/report/app/index.html', min:'manager' },
    { key:'gallery',  label:'사진관리',   icon:'🖼', url:'/gallery/index.html',    min:'manager' },
    { key:'shoot',    label:'작업사진',   icon:'📷', url:'/shoot/index.html',      min:'worker'  },
    { key:'progress', label:'공정관리',   icon:'📈', url:'/progress/index.html',   min:'manager' },
    { key:'status',   label:'인원현황',   icon:'👷', url:'/status/index.html',     min:'manager' },
    { key:'material', label:'자재관리',   icon:'📦', url:'/material/index.html',   min:'manager' }
  ];

  /* role-gate.js가 먼저 실행된 페이지면 그게 만들어둔 판정을 그대로 쓰고,
     게이트를 안 붙인 페이지(checkin 등)에서는 같은 규칙으로 직접 계산한다. */
  var atLeast = window.wrRoleAtLeast || function(min){
    var r = ORDER[localStorage.getItem('member_role') || 'worker'];
    return (r == null ? 0 : r) >= (ORDER[min] == null ? 0 : ORDER[min]);
  };
  APPS = APPS.filter(function(a){ return atLeast(a.min); });

  var current = null;
  for(var i=0;i<APPS.length;i++){
    if(location.pathname.indexOf('/'+APPS[i].key+'/')===0){ current = APPS[i]; break; }
  }


  var style = document.createElement('style');
  style.textContent =
    '#wr-nav-fab{position:fixed;right:max(16px,calc((100vw - 480px)/2 + 16px));bottom:16px;width:52px;height:52px;border-radius:50%;'
      + 'background:rgba(30,58,95,0.88);color:#fff;border:none;box-shadow:0 4px 14px rgba(0,0,0,0.35);'
      + 'font-size:24px;display:flex;align-items:center;justify-content:center;cursor:pointer;z-index:2147483000;'
      + '-webkit-tap-highlight-color:transparent;padding:0;}'
    + '#wr-nav-backdrop{position:fixed;inset:0;background:rgba(0,0,0,0.45);z-index:2147482999;display:none;}'
    + '#wr-nav-backdrop.wr-show{display:block;}'
    + '#wr-nav-menu{position:fixed;right:max(16px,calc((100vw - 480px)/2 + 16px));bottom:78px;z-index:2147483000;display:none;flex-direction:column;gap:8px;align-items:flex-end;}'
    + '#wr-nav-menu.wr-show{display:flex;}'
    + '#wr-nav-menu a{display:flex;align-items:center;gap:10px;background:#fff;color:#1A2332;padding:10px 16px;'
      + 'border-radius:12px;box-shadow:0 4px 14px rgba(0,0,0,0.3);font-size:14px;font-weight:700;text-decoration:none;'
      + 'font-family:Arial,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;white-space:nowrap;}'
    + '#wr-nav-menu a.wr-current{opacity:0.55;pointer-events:none;background:#E8ECF1;}'
    + '#wr-nav-menu a.wr-switch{background:#1E3A5F;color:#fff;margin-top:4px;}'
    + '#wr-nav-menu a .wr-nav-icon{font-size:18px;}'
    + '@media print{#wr-nav-fab,#wr-nav-backdrop,#wr-nav-menu{display:none !important;}}';
  document.head.appendChild(style);

  var backdrop = document.createElement('div');
  backdrop.id = 'wr-nav-backdrop';
  document.body.appendChild(backdrop);

  var menu = document.createElement('div');
  menu.id = 'wr-nav-menu';
  menu.innerHTML = APPS.map(function(a){
    var isCurrent = current && a.key===current.key;
    return '<a href="'+(isCurrent?'javascript:void(0)':a.url)+'"'+(isCurrent?' class="wr-current"':'')+'>'
      + '<span class="wr-nav-icon">'+a.icon+'</span>'+a.label+(isCurrent?' (현재)':'')+'</a>';
  }).join('')
  /* 사진관리·공정관리·인원현황·자재관리에는 로그아웃이 아예 없어서, 한 PC에서 다른 등급
     계정으로 갈아타려면 로그아웃이 있는 앱까지 찾아가야 했다. 여기 하나 두면 어느 화면에서든
     바로 바꿀 수 있다. localStorage는 오리진 단위라 한 브라우저에 한 사람만 로그인된다 —
     여러 계정을 동시에 띄우려면 시크릿 창이나 다른 브라우저 프로필을 써야 한다. */
    + '<a href="javascript:void(0)" class="wr-switch" id="wr-nav-switch">'
    + '<span class="wr-nav-icon">🔄</span>계정 전환</a>';
  document.body.appendChild(menu);

  var SESSION_KEYS = ['member_id','member_name','member_company','member_project','member_phone',
    'member_team','member_menu','member_cat','member_category','member_position','member_is_leader',
    'member_role','senderName'];
  menu.querySelector('#wr-nav-switch').addEventListener('click', function(){
    var who = localStorage.getItem('member_name') || '';
    if(!confirm((who ? who+'님으로 로그인되어 있습니다.\n' : '') + '로그아웃하고 다른 계정으로 로그인할까요?')) return;
    SESSION_KEYS.forEach(function(k){ localStorage.removeItem(k); });
    location.href = '/report/app/login.html';
  });

  var btn = document.createElement('button');
  btn.id = 'wr-nav-fab';
  btn.type = 'button';
  btn.setAttribute('aria-label','다른 화면으로 이동');
  btn.textContent = '⊞';
  document.body.appendChild(btn);

  function setOpen(open){
    backdrop.classList.toggle('wr-show', open);
    menu.classList.toggle('wr-show', open);
  }
  btn.addEventListener('click', function(){ setOpen(!menu.classList.contains('wr-show')); });
  backdrop.addEventListener('click', function(){ setOpen(false); });
}

/* role-gate.js가 등급을 Supabase에서 받아오는 중이면(member_role이 없던 옛 세션) 그게
   끝난 뒤에 그린다 — 안 그러면 아직 worker인 줄 알고 목록을 거의 다 빼버린다. */
if (window.WR_ROLE_READY && typeof window.WR_ROLE_READY.then === 'function') {
  window.WR_ROLE_READY.then(wrBuildNavFab, wrBuildNavFab);
} else {
  wrBuildNavFab();
}
