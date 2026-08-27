# Devoluciones de mercaderia a proveedor

## Objetivo

Registrar retiros fisicos de medicamentos por proveedor sin esperar la nota de credito, para que la disponibilidad sea real desde el momento en que el producto sale del botiquin.

## Regla operativa

1. La hoja de **Devolucion de mercaderia** es el evento operativo.
2. Al aplicar la devolucion, el sistema descuenta inventario inmediatamente.
3. Si el producto tiene lote, se descuenta el lote indicado en la hoja.
4. La nota de credito posterior solo concilia el documento. No vuelve a descontar inventario.

## Estados

- `draft`: documento preparado, sin efecto en inventario.
- `applied_pending_credit_note`: devolucion aplicada; inventario ya descontado; falta conciliar nota de credito.
- `credit_note_reconciled`: devolucion aplicada y nota de credito vinculada.
- `voided`: documento anulado antes de aplicarse.

## Trazabilidad

La devolucion aplicada crea:

- Un movimiento en `inventory_movements` con `movement_type = supplier_return_out`.
- Un movimiento en `inventory_lot_movements` cuando se indica lote.
- Un registro de auditoria `SUPPLIER_RETURN`.

Cada linea aplicada usa una llave `source_event_key` unica para evitar doble descuento por reintento.

## Integracion futura en UI

El panel debe vivir en `inventory-audit.html`, separado del conteo fisico y del ajuste puntual. El formulario debe pedir:

- Proveedor.
- Numero de hoja de devolucion.
- Fecha de retiro.
- Producto.
- Lote y vencimiento.
- Cantidad.
- Motivo de retiro.
- Observacion opcional.

Despues debe existir una accion para conciliar la nota de credito cuando llegue, sin mover inventario.
