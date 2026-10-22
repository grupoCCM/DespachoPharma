# Diferencias de inventario

## Objetivo

Separar la conciliacion operativa del inventario de la investigacion administrativa de faltantes y sobrantes. Un ajuste de stock hace que la aplicacion refleje la existencia fisica, pero no resuelve por si solo una perdida.

## Estados

Cada diferencia tiene dos estados independientes:

- `stock_adjustment_status`: `pending`, `applied` o `not_required`.
- `investigation_status`: `pending_verification`, `open`, `investigating`, `partially_resolved` o `resolved`.

El primer conteo es evidencia inmutable. Una persona distinta realiza el segundo conteo sin ver el esperado ni el primer resultado. La diferencia confirmada es `verified_qty - expected_qty_snapshot`.

## Flujo

1. El conteo detecta una diferencia y crea un expediente.
2. Otro usuario registra el segundo conteo.
3. Admin aplica la diferencia confirmada al inventario.
4. El expediente permanece abierto para investigacion.
5. Admin registra seguimientos y una o mas resoluciones.
6. El caso se cierra cuando todas las unidades quedaron resueltas.

Solo `found_recovered` crea una entrada de inventario. Reintegro, pago, perdida autorizada, error documental, responsabilidad asignada, devolucion a proveedor y otros resultados documentan el cierre sin agregar unidades.

## Seguridad y trazabilidad

- Las escrituras se realizan mediante RPC con sesion y rol validados.
- Verificador y primer contador no pueden ser la misma persona.
- Ajustes y resoluciones usan claves de idempotencia.
- El producto se bloquea transaccionalmente antes de ajustar stock.
- No se permite comprometer unidades reservadas, vencidas o inmovilizadas.
- Casos, eventos y resoluciones no se eliminan; una correccion posterior debe registrarse como un nuevo evento.
- Las tablas tienen RLS habilitado y no admiten escritura directa desde `anon` o `authenticated`.

## Casos historicos del 20/10/2026

- 745, 750 y 771 conservan investigaciones abiertas por faltante fisico.
- 720 es un hallazgo de vencimiento fisicamente presente, no un sobrante patrimonial.
- 730 y 737 corresponden al cruce documental ya corregido.
- 765, 766, 789 y 790 corresponden a compras historicas duplicadas ya documentadas.

La clasificacion historica no crea movimientos nuevos ni altera el conteo original.

## Historial de conteos

El administrador dispone de un historial paginado de sesiones de conteo. Cada
fila separa dos conceptos:

- **Resultado confirmado:** usa la segunda verificacion cuando existe; en los
  demas productos conserva `expected_qty`, `counted_qty`, costo y hallazgos de
  la sesion. Aplicar o conciliar una diferencia no reescribe ese resultado.
- **Conciliacion actual:** muestra si los expedientes de diferencias siguen
  pendientes, estan en proceso o ya fueron resueltos.

Los conteos finalizados y cancelados no se editan. El detalle y la reimpresion
se reconstruyen por `session_id`, por lo que siguen disponibles despues de
recargar la pagina o iniciar sesion desde otro equipo.
