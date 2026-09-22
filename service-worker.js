/* FlotteMine — service worker
   Met en cache la coquille de l'application (HTML, manifeste, icônes)
   pour qu'elle continue à s'afficher hors ligne. Les données (véhicules,
   chauffeurs...) restent gérées séparément par l'app via localStorage. */

const CACHE_NAME = 'flottemine-shell-v3';
const APP_SHELL = [
  './',
  './index.html',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png'
];
// Bibliothèques externes (CDN) dont l'app a besoin dès le chargement.
// Mises en cache à part (requêtes cross-origin "no-cors" → réponses
// opaques, qu'on ne peut pas inspecter mais qu'on peut quand même stocker
// et resservir telles quelles) pour qu'une réouverture hors ligne puisse
// encore se connecter normalement, pas seulement afficher des données figées.
const CDN_SHELL = [
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js',
  'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(async (cache) => {
        await cache.addAll(APP_SHELL);
        await Promise.all(CDN_SHELL.map((url) =>
          fetch(url, { mode: 'no-cors' }).then((resp) => cache.put(url, resp)).catch(() => {})
        ));
      })
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        // Réseau disponible : on sert la réponse fraîche et on met à jour le cache
        // (uniquement les réponses "de base" du même site — pas les réponses
        // opaques cross-origin comme les CDN, qu'on ne peut pas inspecter).
        if (response && response.status === 200 && response.type === 'basic') {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy)).catch(() => {});
        }
        return response;
      })
      .catch(() =>
        caches.match(event.request).then((cached) => {
          if (cached) return cached;
          // On ne retombe sur la page d'accueil que pour une navigation HTML.
          // Pour un script externe (ex. CDN) en échec et non caché, on laisse
          // l'échec réseau remonter tel quel — sinon le navigateur reçoit du
          // HTML à la place d'un script et plante avec "Unexpected token '<'".
          if (event.request.mode === 'navigate') {
            return caches.match('./index.html');
          }
          return Response.error();
        })
      )
  );
});
