// Cache somente do shell estático. Não armazena respostas de Supabase ou dados privados.
const CACHE='mama-manager-pwa-v2';
const SHELL=['/','/index.html','/manifest.webmanifest','/icons/icon.svg'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(Promise.all([caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))),self.clients.claim()]))});
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==self.location.origin)return;if(u.pathname==='/'||u.pathname==='/index.html'){e.respondWith(fetch(e.request).then(res=>{if(res.ok){const copy=res.clone();caches.open(CACHE).then(c=>c.put(e.request,copy))}return res}).catch(()=>caches.match(e.request)));return}if(u.pathname==='/manifest.webmanifest'||u.pathname.startsWith('/icons/'))e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)))});
