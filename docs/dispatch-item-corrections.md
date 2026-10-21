# Correcciones parciales de despachos

## Objetivo

Permitir que un administrador reduzca o retire un producto de un despacho sin borrar el renglón original ni anular los demás productos de la entrega.

## Reglas

- Solo `admin` puede ejecutar la corrección.
- La nueva cantidad debe ser menor que la cantidad efectiva actual.
- El último producto efectivo no se retira: en ese caso se anula el despacho completo.
- Las ventas externas conciliadas y los despachos anulados no se corrigen desde este flujo.
- Un despacho validado solo se corrige cuando las unidades regresaron físicamente al botiquín.
- Los aumentos posteriores a la validación requieren una nueva entrega.

## Efecto por estado

| Estado | Reserva | Inventario físico | Lote |
| --- | --- | --- | --- |
| `draft` legado | Sin cambio | Sin cambio | Sin cambio |
| `confirmed` legado | Sin reserva | Sin cambio | Sin cambio |
| `confirmed` con reservas | Libera la diferencia, preservando primero los lotes FEFO | Sin cambio | Sin cambio |
| `observed` | Ya liberada por Caja | Sin cambio | Sin cambio |
| `validated` | Conserva la reserva `fulfilled` como evidencia | Registra devolución por la diferencia | Regresa al lote consumido originalmente |

## Trazabilidad

- `dispatch_items.original_qty` conserva la cantidad original.
- `dispatch_items.qty` representa la cantidad efectiva.
- Un producto retirado queda con `qty = 0` y `line_status = 'removed'`.
- `dispatch_item_adjustments` conserva cada corrección y su movimiento relacionado.
- `audit_log` registra el evento `DISPATCH_ADJUST_ITEM`.
- Las reservas cumplidas no se eliminan porque documentan lo validado originalmente por Caja.

## Invariantes de validación

1. Todo renglón activo tiene `qty > 0`; todo renglón retirado tiene `qty = 0`.
2. `original_qty >= qty` para todos los renglones.
3. La suma de reservas activas de un despacho confirmado coincide con su cantidad efectiva.
4. Una corrección validada tiene exactamente un movimiento `dispatch_adjust_return`.
5. La suma de movimientos por producto refleja la devolución una sola vez.
6. Anular posteriormente la entrega devuelve solo las cantidades efectivas restantes.
7. Caja nunca presenta ni valida renglones retirados.

## Caso de aceptación: Entrega #633

- Cresadex conserva cantidad efectiva `1`.
- Siprotec pasa de cantidad original `1` a efectiva `0`.
- La reserva cumplida de Siprotec permanece como evidencia.
- Se registra una devolución de `+1` al lote original de Siprotec.
- El encabezado muestra `1` producto y `1` unidad efectiva.
- Historial y exportaciones conservan Siprotec como `Retirado por corrección` y muestran el motivo.
