/* gallery(사진관리)/progress(공정관리) 공용 관리자 암호 게이트.
   개인별 로그인 계정이 아니라, 공용 암호 하나를 아는 사람만 들어오게 하는 간단한 방식.
   한 번 맞히면 이 기기에는 계속 저장돼서(localStorage) 다시 안 물어봄 — PC/모바일 동일하게 동작.
   이 파일 하나만 고치면 gallery/progress 양쪽에 다 반영된다. */
(function(){
  var PIN = '0000';
  if(localStorage.getItem('wr_admin_unlocked')==='1') return;

  var wrap = document.createElement('div');
  wrap.id = 'wrAdminGate';
  wrap.style.cssText = 'position:fixed;inset:0;background:#0d1117;z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:20px;font-family:Arial,"Malgun Gothic",sans-serif;';
  wrap.innerHTML =
    '<div style="background:#161b22;border:1px solid #30363d;border-radius:12px;padding:28px 24px;max-width:320px;width:100%;text-align:center;">'
      + '<div style="font-size:32px;margin-bottom:10px;">🔒</div>'
      + '<div style="font-size:15px;font-weight:700;color:#e6edf3;margin-bottom:16px;line-height:1.5;">관리자 전용 화면입니다<br>암호를 입력하세요</div>'
      + '<input type="password" id="wrAdminPin" inputmode="numeric" style="width:100%;background:#0d1117;border:1px solid #30363d;border-radius:8px;color:#e6edf3;font-size:16px;padding:10px 12px;text-align:center;margin-bottom:10px;box-sizing:border-box;" placeholder="암호">'
      + '<button type="button" id="wrAdminGateBtn" style="width:100%;background:#2f81f7;border:none;border-radius:8px;color:#fff;font-size:14px;font-weight:700;padding:10px;cursor:pointer;">확인</button>'
      + '<div id="wrAdminGateErr" style="color:#f85149;font-size:12px;margin-top:8px;display:none;">암호가 틀렸습니다</div>'
    + '</div>';
  document.body.appendChild(wrap);

  var input = document.getElementById('wrAdminPin');
  function tryUnlock(){
    if(input.value.trim()===PIN){
      localStorage.setItem('wr_admin_unlocked','1');
      wrap.remove();
    } else {
      document.getElementById('wrAdminGateErr').style.display='block';
      input.value=''; input.focus();
    }
  }
  document.getElementById('wrAdminGateBtn').onclick = tryUnlock;
  input.addEventListener('keydown', function(e){ if(e.key==='Enter') tryUnlock(); });
  setTimeout(function(){ input.focus(); }, 100);
})();
