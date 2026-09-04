# Productos / Dispositivos

## Objetivo

Controlar productos no farmacos dentro de Botiquin CCM sin mezclarlos con medicamentos. El acceso y la sesion son los mismos, pero inventario, despacho, historico y reportes quedan separados.

## Alcance inicial

Productos base analizados:

- `804` Estudio diagnóstico de apnea del sueño
- `805` SIBIONICS GS1 CGM (Monitoreo de Glucosa)

El despacho puede registrarse como venta definitiva o como reposicion. Cada unidad debe tener un codigo unico propio, por ejemplo:

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
3. En dispositivos, el usuario digita expediente, elige `Venta` o `Reposicion`, y escanea/digita el codigo unico.
4. La aplicacion valida que la unidad exista y este disponible.
5. Si elige `Reposicion`, debe indicar motivo.
6. Al confirmar, la unidad pasa a estado `sold`.

En una reposicion:

- Se descuenta inventario igual que una venta.
- El precio de venta queda en `0`.
- El costo se conserva para trazabilidad y analisis operativo.
- El historico muestra el tipo `Reposicion` y el motivo registrado.

## Flujo administrativo

1. Admin entra a Productos / Dispositivos.
2. Registra una unidad nueva con:
   - Producto base.
   - Codigo unico.
   - Costo.
   - Lote y vencimiento si aplica.
   - Documento o comentario.
3. La unidad queda disponible para venta.

## CRUD administrativo

La administracion de dispositivos debe ser trazable. La accion normal no es borrar datos historicos, sino corregir o retirar unidades con motivo.

Funciones incluidas en la migracion `064_device_admin_crud.sql`:

- Carga masiva de codigos unicos desde pantalla admin.
- Consulta administrable por serial, producto, documento, expediente o estado.
- Correccion de unidades disponibles: producto, lote, vencimiento, costo, documento y comentario.
- Retiro administrativo de unidades disponibles: retirado, danado, perdido o inactivo.
- Auditoria de cambios admin en `device_admin_audit`.

Reglas:

- Solo admin puede corregir o retirar unidades.
- Solo unidades `available` pueden ser corregidas o retiradas.
- Una unidad vendida no se modifica desde CRUD; requiere un flujo separado de anulacion de venta.
- Toda correccion o retiro requiere motivo.

## Historico y reportes

El historico de dispositivos vive dentro de `history.html`, separado por pestaña de farmacia.

Incluye:

- Filtros por fecha, estado y texto libre.
- Busqueda por venta, expediente, producto, codigo unico o usuario.
- Resumen de registros, unidades activas/anuladas, venta y utilidad.
- Detalle por venta con cada codigo unico despachado.
- Exportacion CSV y PDF independiente del reporte de farmacia.

La capa de datos esta en la migracion `065_device_sales_history.sql`:

- `rpc_device_sales_history`
- `rpc_device_sale_detail`

Estas funciones son solo de lectura y requieren usuario admin.

La migracion `067_device_replacement_flow.sql` agrega:

- `device_sales.sale_type`
- `device_sales.replacement_reason`
- `device_sale_items.sale_type`
- Variante de `rpc_device_dispatch_submit` compatible con `p_sale_type` y `p_reason`.

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
- Importacion operativa de compras de productos no farmacos.
