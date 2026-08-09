// 이 파일 내용이 바뀌어야 브라우저가 새 버전을 감지해 업데이트 배너를 띄운다.
// index.html/admin.html/report-pdf.html 등을 배포할 때마다 아래 버전 문자열을 함께 올려줄 것.
const SW_VERSION = '2026-08-09-5';
const CACHE = 'wr-report-' + SW_VERSION;

/* 오프라인 대비 캐시(2026-08-09 추가).
   예전에는 fetch 실패 시 caches.match()로 넘어가게만 해두고 캐시에 아무것도 넣지 않아서,
   오프라인이면 항상 빈 결과가 나왔다 — 즉 오프라인 지원이 사실상 없는 상태였다.
   이제 온라인일 때 성공한 응답을 그때그때 저장해두고, 네트워크가 끊겼을 때만 그걸 내준다.

   지켜야 할 것 세 가지:
   1) 화면(navigate)은 계속 network-first(no-store) — 온라인이면 항상 최신 HTML을 받는다.
      캐시는 어디까지나 네트워크가 죽었을 때의 대비책이다.
   2) Supabase 데이터 요청(rest/auth/realtime/storage)은 서비스워커가 아예 손대지 않는다.
      오래된 일보·사진 목록을 최신인 척 보여주는 건 아예 안 열리는 것보다 나쁘다.
   3) sw.js 자신은 캐시하지 않는다 — 캐시되면 업데이트 감지가 멈춰버린다. */
const BYPASS = /supabase\.co\/(rest|auth|realtime|storage)\/|\/sw\.js(\?|$)/;

function shouldCache(res) {
  if (!res) return false;
  // CDN 스크립트는 opaque(status 0)로 오지만 오프라인 재생에 꼭 필요하므로 함께 저장한다.
  return res.ok || res.type === 'opaque';
}

async function networkFirst(req, init) {
  const res = await fetch(req, init);
  if (shouldCache(res)) {
    const copy = res.clone();
    caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
  }
  return res;
}

self.addEventListener('install', e => {
  // 첫 방문 직후 바로 오프라인이 되는 경우를 위한 최소 선캐시. 실패해도 무시한다
  // (온라인으로 한 번 열기만 하면 아래 networkFirst가 어차피 채운다).
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.add(new URL('index.html', self.registration.scope).href))
      .catch(() => {})
  );
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    // 버전이 바뀌면 예전 캐시는 통째로 버린다 — 옛 HTML이 남아 되살아나는 걸 막는다.
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k.startsWith('wr-report-') && k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', e => {
  const req = e.request;
  // GET이 아니거나 Supabase 데이터 요청이면 서비스워커가 개입하지 않고 그대로 흘려보낸다.
  if (req.method !== 'GET' || BYPASS.test(req.url)) return;

  const init = req.mode === 'navigate' ? { cache: 'no-store' } : undefined;
  e.respondWith((async () => {
    try {
      return await networkFirst(req, init);
    } catch (err) {
      const hit = await caches.match(req);
      if (hit) return hit;
      // 처음 보는 주소로 오프라인 접속한 경우엔 최소한 앱 첫 화면이라도 띄워준다.
      if (req.mode === 'navigate') {
        const shell = await caches.match(new URL('index.html', self.registration.scope).href);
        if (shell) return shell;
      }
      throw err;
    }
  })());
});

self.addEventListener('message', e => { if (e.data === 'SKIP_WAITING') self.skipWaiting(); });
