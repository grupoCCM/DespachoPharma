# Productos / Dispositivos

## Objetivo

Controlar productos no farmacos dentro de Botiquin CCM sin mezclarlos con medicamentos. El acceso y la sesion son los mismos, pero inventario, despacho, historico y reportes quedan separados.

## Alcance inicial

Productos base analizados:

- `804` Estudio diagnóstico de apnea del sueño
- `805` SIBIONICS GS1 CGM (Monitoreo de Glucosa)

El despacho se maneja como venta definitiva. Cada unidad debe tener un codigo unico propio, por ejemplo:

- Apnea: `AA2601GW80`
- Glucosa: `2606386QBG78EEAN30`

## Regla principal

Farmacia controla producto, cantidad, lote y vencimiento.

Dispositivos controla producto y unidad serializada. No se puede vender una unidad si el codigo unico:

- No existe.
- Esta vendido.
- Esta inactivo, danado, perdido o retirado.
- Ya fue agregado al carrito actual.

## Flujo operativo

1. El despachador entra con su PIN.
2. El sistema muestra selector de despacho:
   - Farmacia
   - Dispositivos
3. En dispositivos, el usuario digita expediente y escanea/digita el codigo unico.
4. La aplicacion valida que la unidad exista y este disponible.
5. Al confirmar, la unidad pasa a estado `sold`.

## Flujo administrativo

1. Admin entra a Productos / Dispositivos.
2. Registra una unidad nueva con:
   - Producto base.
   - Codigo unico.
   - Costo.
   - Lote y vencimiento si aplica.
   - Documento o comentario.
3. La unidad queda disponible para venta.

## Separacion de datos

La migracion `063_device_products_module.sql` crea tablas nuevas:

- `device_products`
- `device_units`
- `device_sales`
- `device_sale_items`
- `device_inventory_movements`

No modifica las tablas de farmacia ni sus movimientos.

## Pendientes

- Importacion operativa de compras de productos no farmacos.
- Conciliacion entre compras esperadas y seriales realmente registrados.
- Dashboard comercial separado de dispositivos.
- Reporte de utilidad usando el archivo `Utilidad por Articulo`.
- Historico descargable a Excel/PDF.
- Manejo de anulacion de venta de dispositivos, si el proceso operativo lo requiere.
