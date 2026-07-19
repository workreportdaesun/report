/* 4개 앱(report/gallery/shoot/progress) 어디서나 다른 앱으로 바로 이동하는 공용 플로팅 버튼.
   이 파일 하나를 고치면 4개 앱 전체에 반영된다 — 각 페이지에는
   <script src="/report/nav-fab.js"></script> 한 줄만 넣으면 됨. */
(function(){
  var APPS = [
    { key:'report',   label:'작업일보', icon:'📋', url:'/report/app/index.html' },
    { key:'gallery',  label:'사진관리', icon:'🖼', url:'/gallery/index.html' },
    { key:'shoot',    label:'작업사진', icon:'📷', url:'/shoot/index.html' },
    { key:'progress', label:'공정관리', icon:'📈', url:'/progress/index.html' }
  ];
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
  }).join('');
  document.body.appendChild(menu);

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
})();
