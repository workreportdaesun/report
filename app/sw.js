// 이 파일 내용이 바뀌어야 브라우저가 새 버전을 감지해 업데이트 배너를 띄운다.
// index.html/admin.html/report-pdf.html 등을 배포할 때마다 아래 버전 문자열을 함께 올려줄 것.
const SW_VERSION = '2026-08-06-26';
self.addEventListener('install', e => {});
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  if (e.request.mode === 'navigate') {
    e.respondWith(fetch(e.request, { cache: 'no-store' }).catch(() => caches.match(e.request)));
    return;
  }
  e.respondWith(fetch(e.request).catch(() => caches.match(e.request)));
});
self.addEventListener('message', e => { if (e.data === 'SKIP_WAITING') self.skipWaiting(); });
