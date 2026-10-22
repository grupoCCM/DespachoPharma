# Control de sesion

## Objetivo

Las pantallas protegidas no deben mostrar navegacion, datos ni controles hasta que
`rpc_session_touch` confirme que la sesion sigue vigente y que el rol tiene acceso.
La validacion del navegador mejora la experiencia, pero las RPC siguen siendo la
autoridad para autorizar lecturas y escrituras.

## Contrato de una pantalla protegida

1. Declarar los roles permitidos en `data-session-roles` del `body`.
2. Cargar `app-session.js` inmediatamente despues de abrir el `body`.
3. Cargar `app-nav.js` despues de `app-session.js`, cuando corresponda.
4. Esperar `AppSession.requireSession({ roles:[...] })` al inicio de `init`.
5. Mantener la validacion de sesion y rol dentro de cada RPC critica.

Mientras se valida, el documento permanece en `app-session-pending`. Una sesion
valida habilita la pantalla y sincroniza `dp_expires_at`. Una sesion rechazada
limpia el almacenamiento local y usa `location.replace("index.html")`.

## Renovacion y fallas de red

- La actividad real de teclado, toque o clic renueva la sesion de forma limitada,
  no en cada evento.
- Cada respuesta valida actualiza el vencimiento local con el valor del servidor.
- Al volver a una pestana o restaurarla desde el historial se revalida la sesion.
- Una falla de red no se interpreta como sesion revocada: la pantalla se bloquea,
  conserva su estado en memoria y permite reintentar.
- Al alcanzar el vencimiento local, la pantalla se bloquea antes de consultar al
  servidor. Solo vuelve a mostrarse si la sesion es confirmada.

## Pantallas publicas

`index.html` y `availability.html` siguen siendo publicas. No cargan el guard.
Si encuentran una sesion almacenada, la validan y guardan el nuevo vencimiento;
si no existe o fue rechazada, su funcionalidad publica permanece disponible.

## Validacion

```powershell
node tests/check-session-guard.js
node tests/check-inline-js.js dashboard.html imports.html purchasing.html expiration-dashboard.html inventory-audit.html catalog.html history.html device-inventory.html cashier.html dispatch.html dispatch-menu.html device-dispatch.html availability.html index.html
```

El smoke de navegador `tests/smoke-session-guard.js` cubre redireccion sin sesion,
renovacion, rechazo del servidor, bloqueo recuperable sin red y disponibilidad
publica con sincronizacion de una sesion valida.
