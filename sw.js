var CACHE='gad-v3';
var SHELL=['./','./index.html','./admin.html','./manifest.webmanifest','./logo-v2.png','./pattern.png','./icon-192.png','./icon-512.png'];
self.addEventListener('install',function(e){e.waitUntil(caches.open(CACHE).then(function(c){return c.addAll(SHELL)}).catch(function(){}));self.skipWaiting()});
self.addEventListener('activate',function(e){e.waitUntil(caches.keys().then(function(ks){return Promise.all(ks.filter(function(k){return k!==CACHE}).map(function(k){return caches.delete(k)}))}));self.clients.claim()});
self.addEventListener('fetch',function(e){var u=new URL(e.request.url);
 if(u.origin!==location.origin||e.request.method!=='GET')return;
 if(e.request.mode==='navigate'||u.pathname.endsWith('.html')){e.respondWith(fetch(e.request).then(function(r){if(r.ok){var c=r.clone();caches.open(CACHE).then(function(cc){cc.put(e.request,c)})}return r}).catch(function(){return caches.match(e.request).then(function(m){if(m)return m;if(u.pathname.indexOf('admin.html')>-1)return new Response('تعذر تحميل صفحة الأدمن — اتأكد من النت',{status:503,headers:{'Content-Type':'text/html; charset=utf-8'}});return caches.match('./index.html')})}));return}
 e.respondWith(caches.match(e.request).then(function(m){return m||fetch(e.request).then(function(r){if(r.ok){var c=r.clone();caches.open(CACHE).then(function(cc){cc.put(e.request,c)})}return r}).catch(function(){return m})}))});
